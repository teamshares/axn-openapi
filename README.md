# axn-openapi

> **⚠️ Status: unreleased proof of concept — not used in production.**
> This gem exists primarily as a **testbed**: it's the first non-LLM consumer of axn core's tool
> machinery, built to prove that the core tool/reflection/versioning semantics generalize beyond the
> MCP/LLM use-cases they were originally designed against. It is **not published, not
> production-hardened, and not deployed anywhere yet.** Treat the API, URL scheme, and config surface
> as unstable and subject to change. Use it to experiment and to stress-test axn core — not (yet) to
> serve real traffic.

Serve [Axn](https://github.com/teamshares/axn) actions as an OpenAPI-described JSON HTTP API. Give
it a set of Axns; it auto-generates an OpenAPI 3.1 document, routes inbound HTTP requests to the
right Axn, runs it through axn core's sanctioned tool invoker, and returns JSON.

**Author once, expose anywhere.** You write a plain Axn — a normal action, usable by any caller —
and this gem exposes it over HTTP with `Axn::OpenAPI.app` (a mountable Rack app) or
`Axn::OpenAPI::Controller` (a mixin for your own controller). The Axn itself stays plain: called
directly it returns an `Axn::Result`, with no HTTP awareness. The same action can be exposed to
other adapters (e.g. `axn-mcp`) the same way, from the same class.

**Model: RPC-over-HTTP, not REST resources.** Axns are verbs/commands (`ApproveLoan`,
`RecalculateBalance`), not nouns with a CRUD verb set — so it's one `POST` endpoint per Axn, not a
resource-per-noun scheme.

## Installation

Add to your Gemfile:

```ruby
gem "axn-openapi"
```

Then run:

```bash
bundle install
```

## Quick start

Write a plain Axn, mark it for this adapter (or drop it under a directory root — see
[Membership](#membership-directory-roots--the-tool-dsl)), and mount the app:

```ruby
class ApproveLoan
  include Axn
  tool :openapi

  description "Approve a pending loan"
  expects :loan_id, type: Integer
  exposes :status, type: String

  def call
    loan = Loan.find(loan_id)
    fail!("Loan already decided") unless loan.pending?

    loan.approve!
    expose status: "approved"
  end
end
```

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Axn::OpenAPI.app(auth: Axn::Extensions::Auth::Bearer.new(keys: { "frontend" => -> { ENV.fetch("API_KEY") } })) => "/api"
end
```

`auth:` is required. Pass a strategy, or `auth: :none` to serve unauthenticated on purpose (see
[Authentication](#authentication)). `Axn::OpenAPI.app` defaults to every registered `:openapi` tool
on the default mount. **The mount point is the path
prefix** — `mount ... => "/api"` means `ApproveLoan` is served at `POST /api/approve_loan/v1`, and
the generated spec at `GET /api/openapi.json`. Every route is versioned: the path is
`{mount}{path_prefix}/{tool}/v{n}`, where `n` is the Axn's `tool_version` (undeclared ⇒ `1`). There
is no bare, default, or "latest" path — a second version added later (`tool_version 2` on another
Axn sharing the same `tool_name`) is addressable at its own `/v2` path alongside the existing `/v1`,
never in place of it. `curl`:

```bash
curl -X POST http://localhost:3000/api/approve_loan/v1 -H "Authorization: Bearer $API_KEY" -d '{"loan_id": 42}'
# => {"status":"approved"}

curl -H "Authorization: Bearer $API_KEY" http://localhost:3000/api/openapi.json
# => the OpenAPI 3.1 document
```

The document's `paths` are mount-relative (they read `/approve_loan/v1`, not `/api/approve_loan/v1`),
but when the app is mounted below the origin root the served document publishes the mount base as its
`servers` entry (`"servers": [{ "url": "/api" }]`, derived from the request's `SCRIPT_NAME`) — so
`server.url + path` is the real endpoint and generated clients / interactive tooling target the right
URL. A root-mounted app omits `servers` (OpenAPI's `/` default already applies). To find the newest
version of a tool, read the spec's `paths` and take the highest `vN` for that tool — there is no
dedicated "latest" endpoint or route.

The gem is framework-agnostic — `Axn::OpenAPI.app` is a plain Rack app, so it also `run`s in a bare
`config.ru` outside Rails entirely.

## Two ways to serve tools

Both skins run through the same dispatcher (`Axn::OpenAPI::Dispatcher`), so status/envelope
behavior is identical either way — pick based on whether you want this gem to own routing.

### 1. Mount the app (`Axn::OpenAPI.app`)

Owns routing: one `POST /<tool_name>/v<n>` route per registered tool *version*, plus
`GET /openapi.json` (or your configured `spec_path`). Use this when you don't need per-tool
routing/filters.

```ruby
Axn::OpenAPI.app(auth:, mount: nil, tools: nil, authorize: nil, context: nil, public_spec: false,
                 info: nil, path_prefix: nil, spec_path: nil)
```

- **`auth:`** is **required**. It takes a strategy, an Array of strategies (any one of them may
  authenticate), or `:none`. See [Authentication](#authentication).
- **`mount:`** takes a Symbol naming a mount, and the app serves the tools bound to that mount (see
  [Mounts](#mounts-keeping-tool-sets-apart)). The default (nil) is the unnamed mount, which serves only
  tools that name no mount.
- **`tools:`** takes an explicit array (`[ApproveLoan, RejectLoan]`) to serve instead of the mount's
  registered tools.
- **`authorize:`** takes `->(principal, axn_class) { true/false }` and replaces the tool's
  `allowed_callers` check (see [403](#authorization-403)).
- **`context:`** takes `->(env) { {...} }` or `->(env, principal) { {...} }` (the principal is passed
  whenever the callable can take a second positional argument), which is resolved into the
  trusted `ambient_context` (see [below](#ambient_context-the-authrequest-context-seam)). It is evaluated
  only when a tool is actually dispatched, and defaults to an empty Hash.
- **`public_spec:`** set to true serves the OpenAPI document without authentication. By default the
  document is gated like the tools. A public document names every tool on the mount, so don't set it
  on a mount whose tool list is itself sensitive.
- **`info:`** takes `{ title:, version:, description: }`, which is merged over the configured
  `info_*` for this mount's document.
- **`path_prefix:`** / **`spec_path:`** override the configured defaults for this app instance.

### 2. `include Axn::OpenAPI::Controller`

You own routing/auth/filters (a normal Rails controller + `config/routes.rb` entry); the mixin just
runs the Axn and renders the result.

```ruby
class LoansController < ApplicationController
  include Axn::OpenAPI::Controller

  def approve
    render_axn(ApproveLoan, ambient_context: { current_user_id: current_user.id })
  end
end
```

```ruby
# config/routes.rb
post "/loans/:id/approve", to: "loans#approve"
```

`render_axn(axn_class, ambient_context: {})` reads `request.raw_post` and parses it through the same
shared body parser the mount uses, so it behaves identically: a blank body is a bodyless call
(`{}`), a valid JSON object is the params, and a **malformed body (or a non-object JSON value) renders
a `400`** — it is not silently dispatched as `{}`. It then runs the Axn through `Dispatcher` and calls
`render json:, status:`. The module references no Rails constants at load time, so it works with any
duck-typed `request`/`render`.

#### Routing: mount vs. controller (and a recommendation)

The two skins differ in **who owns the URL**. The mount owns its routes, so it auto-generates the
versioned scheme `{mount}{path_prefix}/{tool}/v{n}` (as described above). The controller skin does
**not** touch your routes: `render_axn` dispatches whatever Axn you hand it at whatever path *you*
declare in `config/routes.rb`. That's deliberate — the controller skin exists for consumers who want
their own routing/auth/filters — so nothing injects `/v1` into a controller route for you.

**Recommendation: bake the version segment into your controller routes from day one** to match the
mount's convention:

```ruby
# Prefer this — versioned from the start:
post "/loans/approve/v1", to: "loans#approve"   # -> render_axn(ApproveLoan::V1) (or the v1 class)

# ...rather than a bare:
post "/loans/approve",    to: "loans#approve"
```

Rationale: a versioned path makes a future breaking change **additive** — you add `POST .../v2`
routed to the v2 Axn, and existing `/v1` clients are untouched — whereas a bare route forces you to
either break its contract in place or bolt on versioning later (a migration for every caller). It
also keeps your hand-rolled surface consistent with the mount's `/{tool}/v{n}` scheme, so the whole
API reads one way. (The gem can't do this for you here — it doesn't own controller routes — but the
convention is the same one the mount enforces automatically.)

## Authentication

Every mount must say how it authenticates. The gem is **fail-closed**: `Axn::OpenAPI.app` raises at
build time without `auth:`, and `auth: :none` is the only way to serve unauthenticated.

Strategies come from axn core's `Axn::Extensions::Auth` (also used by axn-webhooks). The built-in
one is a static API key:

```ruby
# `Authorization: Bearer <key>`; the principal is the key's name
Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => -> { ENV.fetch("PIPELINE_API_KEY") } })

# The raw value of a custom header
Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => -> { ENV.fetch("PIPELINE_API_KEY") } }, header: "X-API-Key")
```

- **Key values.** A key can be a String, a Proc, or an Array of them. A Proc is resolved **on every
  request**, so a rotated secret needs no restart. Listing the old and new key together overlaps a
  rotation.
- **Comparison.** Every key is compared in constant time.
- **Misconfiguration.** A blank key raises (a 500, reported) rather than authenticating anyone.
- **Redaction.** Keys never appear in `inspect`, `pp` or logs.

Each request is **authenticated before it is routed**, so an unauthenticated caller gets `401` for
every path, including unknown ones, and can't probe which tools exist. The 401 carries every
strategy's challenge (`www-authenticate: Bearer`). The served OpenAPI document is gated the same
way unless the mount passes `public_spec: true`.

**Any strategy works.** A strategy is any object with `#call(request)` that returns a verdict: an
`Axn::Extensions::Auth::Verdict`, anything answering `ok?`/`principal`, or a boolean. The request
answers `#header(name)`. A JWT verifier written in your app, for example:

```ruby
jwt = ->(request) do
  claims = MyJwt.verify(request.header("Authorization").to_s.delete_prefix("Bearer "), aud: "os-integration-credentials")
  claims ? Axn::Extensions::Auth::Verdict.ok(claims["iss"]) : Axn::Extensions::Auth::CREDENTIALS_MISMATCH
end

Axn::OpenAPI.app(
  auth: [api_key, Axn::OpenAPI.documented_auth(jwt, security_scheme: { type: "http", scheme: "bearer", bearerFormat: "JWT" }, name: "jwt")],
  mount: :credentials,
)
```

`documented_auth` pairs a strategy the gem can't describe on its own with the security scheme that
describes it in the document. For an `http` scheme it also supplies the 401's `WWW-Authenticate`
challenge (`Bearer` for `scheme: "bearer"`) when the wrapped strategy doesn't give its own.
`Bearer` needs no wrapping: it documents itself as `http`/`bearer`, or as `apiKey` for a custom
header. A strategy the gem can't describe is refused at build time, so the
document never omits how the mount authenticates.

**Return a String principal id** (or a Symbol) from a custom strategy. Allowlists match on it, and
logs record it. Any other principal object is recorded only by its class name, so claims never leak.
**Never put the presented token into an exception message** from a custom strategy. Exception
messages reach `on_exception` verbatim, and context redaction can't reach inside them.

### Authorization (403)

A tool can restrict which authenticated principals may call it:

```ruby
class IntegrationCredentials
  include Axn
  tool openapi: { mount: :credentials, allowed_callers: ["data_pipeline"] }
  # ...
end
```

An authenticated caller who isn't on the list gets `403 {"error": {"message": "Forbidden"}}`. The
check runs before the verb check, so a forbidden caller learns nothing more about the path. A tool
without `allowed_callers` admits any authenticated caller.

Pass `authorize: ->(principal, axn_class) { ... }` on the mount to replace that check. The default is
public as `Axn::OpenAPI.allowed_caller?(principal, axn_class)`, so a custom policy can compose with
it. The policy's answer is read like a verdict: `ok?` first, then truthiness. So a policy that
returns an `Axn::Result` or an `Axn::Extensions::Auth::Verdict` denies when that object is not ok.

These combinations fail at build time instead of at request time:

- a tool with `allowed_callers` on an `auth: :none` mount;
- `authorize:` with `auth: :none`;
- an `allowed_callers` entry that none of the mount's strategies can authenticate as. This check is
  skipped for a strategy that can't list its principals, such as a JWT verifier.

The controller skin enforces the same boundaries:

- **Allowlist.** Pass `render_axn(Tool, principal: ...)` with the caller your controller
  authenticated. Use a principal that came out of real authentication, never a caller-asserted
  header. Calling it on a tool that declares `allowed_callers` without a `principal:` raises rather
  than silently ignoring the list.
- **Mount binding.** A tool bound to a mount can be rendered only with a matching
  `render_axn(Tool, mount: :credentials, ...)`, so a controller can't expose it past that mount's
  auth by accident.

### Observability

Authentication and authorization run as Axns (`Axn::OpenAPI::Authenticate` / `Axn::OpenAPI::Authorize`),
so every request emits axn's own `axn.call` event, OpenTelemetry span and log line, including a
`401`/`403` that never reaches a tool. They carry a `mount` dimension, a `reason` dimension
(`credentials_missing` / `credentials_mismatch`), a `principal` tag and an `operation_id` tag.

Every call on a mount is stamped `invoked_via: openapi`, on both the gate Axns and the tool. For an
audit trail of what was read, declare `tag`/`dimension` on the tool itself:

```ruby
class IntegrationCredentials
  include Axn
  expects :caller_id, on: :ambient_context, type: String
  expects :company_uuid, type: String
  tag :caller_id, :caller_id
  tag :company_uuid, :company_uuid
end

Axn::OpenAPI.app(auth: pipeline_key, mount: :credentials, context: ->(_env, principal) { { caller_id: principal } })
```

The presented credential is never logged: the gate's inputs are `sensitive:`, and `Request#inspect`
redacts headers and body. **The gem redacts the gate, not your tool.** axn logs a tool's inputs and
exposures on every call, so declare anything secret `sensitive: true`:

```ruby
exposes :client_secret_ciphertext, type: String, sensitive: true
``` The authenticated principal is also available to Rack middleware as
`env["axn.openapi.principal"]`.

## Mounts: keeping tool sets apart

One app can serve several independent mounts, each with its own tools, auth, `info` and document.
Bind a tool to a mount on the Axn itself:

```ruby
class IntegrationCredentials
  include Axn
  tool openapi: { mount: :credentials }
end

mount Axn::OpenAPI.app(auth: :none) => "/api"            # the default mount: never serves IntegrationCredentials
mount Axn::OpenAPI.app(auth: pipeline_key, mount: :credentials, info: { title: "Credentials API" }) => "/internal/credentials"
```

- **A mount serves only its own tools.** `Axn::OpenAPI.app(mount: :credentials)` serves exactly the
  tools that declare `mount: :credentials`. The default mount serves only tools that name no mount.
- **A mismatched explicit tool fails at boot.** Passing `tools:` that includes a tool declared for a
  different mount raises. An explicit list of tools that declare no mount works on any mount (an
  ad-hoc mount).
- **One tool, one mount; one build per mount.** Building a mount that would serve a tool another
  mount already serves raises at boot. So does building the same mount a second time from a
  different place, because two live apps under one name could otherwise serve its tools with
  different auth. Give each ad-hoc mount its own `mount:` name.
- **Reloads.** Under Rails, a mount built while routes are drawn belongs to that route set, and
  clearing the route set releases it. Every route reload clears before it redraws, so reloading
  after an edit that moves the mount's line works. Building one mount twice within a single draw
  raises, even from the same line inside a loop. Outside a route draw, rebuilding from the same
  place replaces the claim. "The same place" is the whole chain of your application's frames that
  led to the build, so a shared helper called from two different lines is two builds and raises.
  The Rails hook is installed by a Railtie, which requires `axn-openapi` to load after Rails, as
  `Bundler.require` does.
- **Tests.** Suites that build many apps should call `Axn::OpenAPI.reset_mounts!` between examples.

**Keep restricted tools out of `app/agent_tools/`.** That directory is the default `tool_roots` for
*every* axn adapter, so a tool placed there is also served over MCP and ruby_llm. Put a credentials tool
somewhere else, such as `app/credentials_tools/`, and declare `tool openapi: { mount: :credentials }`.
To bind a whole folder, give its tools a shared base class that calls `configure(:openapi) { |c| c.mount = :credentials }`.

## `ambient_context`: the auth/request-context seam

Axns don't know about HTTP, sessions, or `current_user` — those are request-scoped, and a plain
Axn should stay callable outside a request entirely. `ambient_context` is the seam: a Hash of
trusted, request-derived values that flows into the Axn's own `expects ..., on: :ambient_context`
fields, same as any other adapter (`axn-mcp`, `axn-ruby_llm`) uses.

**Authentication identifies the caller; `ambient_context` is how that reaches the Axn.** Nothing is
injected automatically. You decide what goes into `ambient_context`: the mount's `context:` (whose
second parameter is the authenticated principal) or the `ambient_context:` kwarg to `render_axn`.

```ruby
class ApproveLoan
  include Axn
  tool :openapi

  expects :loan_id, type: Integer
  expects :approver_id, on: :ambient_context, type: Integer

  def call
    # ...
  end
end

# Mount skin — read a header/session value per request, or use the authenticated principal:
Axn::OpenAPI.app(auth: :none, context: ->(env) { { approver_id: env["rack.session"]["user_id"] } })
Axn::OpenAPI.app(auth: api_key, context: ->(_env, principal) { { approver_id: principal } })

# Controller skin — build it from the controller's own auth:
render_axn(ApproveLoan, ambient_context: { approver_id: current_user.id })
```

`ambient_context` fields are excluded from the generated `input_schema`/OpenAPI `requestBody`
automatically — they're never something the caller supplies in the request body. If the
`ambient_context` you build is itself malformed (missing/wrong-typed), that's a **server bug**, not
a caller error — it surfaces as a 500, not a 400 (see the status table below).

## Membership: directory roots + the `tool` DSL

A class's `:openapi` membership is `(directory-root grant ∪ tool declaration) − except`, the same
convention `axn-mcp`/`axn-ruby_llm` use:

- **Directory roots** — every Axn whose file lives under a configured `tool_roots` entry is granted
  automatically, no `tool` declaration needed. Default root: `agent_tools` (i.e. `app/agent_tools/`
  in a Rails app) — the same default as the sibling adapters, so a tool dropped there is exposed
  over every adapter at once.
- **`tool :openapi`** — explicitly adds `:openapi` membership for a tool outside the roots. Bare
  `tool` grants every registered adapter.
- **`tool except: :openapi`** — keeps a directory grant but removes `:openapi`. `tool false` opts
  out of every adapter.

`Axn::OpenAPI.tools(mount: nil)` enumerates the current membership bound to a mount, across every
declared version of each tool (`Axn::Tools.for(:openapi, all_versions: true)` filtered by each tool's
`mount`). It is the default source for `.app`/`.spec` when you don't pass an explicit `tools:` list.

## Configuration

```ruby
Axn::OpenAPI.config.path_prefix = "/axns"
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `path_prefix` | `""` | Prepended to every tool route when computing the spec's paths and (for the mount skin) when matching an inbound request. Purely cosmetic when mounting — the mount point (`mount ... => "/api"`) already does the real prefixing at the Rack level. |
| `spec_path` | `"/openapi.json"` | Where the mount skin serves the generated OpenAPI document (`GET`). |
| `reject_undeclared_inputs` | `false` (lenient) | `false`: unknown top-level body keys are silently ignored (matches JSON Schema's `additionalProperties`-permitted posture; forward-compatible across client/server version skew). `true`: an unknown key fails as a 400, same bucket as any other input-contract violation, and the published request schema tightens to `additionalProperties: false` to match. A typo on a *required* field always fails regardless of this setting. Settable per tool — see [Per-tool overrides](#per-tool-overrides). |
| `reject_opaque_exposed_values` | `true` (strict) | `true`: an exposed value with no JSON rendering *its author declared* is a 500 rather than a body containing `"#<User:0x...>"` (or, in Rails, an instance-variable dump). `false`: that rendering ships, matching axn-mcp's default. See [Rejecting opaque exposed values](#rejecting-opaque-exposed-values-reject_opaque_exposed_values). |
| `mount` | `nil` | Per tool (`tool openapi: { mount: :name }`): which mount serves it. See [Mounts](#mounts-keeping-tool-sets-apart). |
| `allowed_callers` | `nil` | Per tool: principal ids allowed to call it (non-empty Array); `nil` admits any authenticated caller. See [403](#authorization-403). |
| `info_title` | `"Axn API"` | OpenAPI `info.title`. |
| `info_version` | `"1.0.0"` | OpenAPI `info.version`. |
| `info_description` | `nil` | OpenAPI `info.description`; omitted from the document when nil. |
| `tool_roots` | `%w[agent_tools]` | Directory roots granting implicit `:openapi` membership (see above). Validated: a broad entry (`app`, `.`, `actions`, a `..` traversal) is rejected. |

### Per-tool overrides

`mount` and `allowed_callers` describe a tool, so they are set per tool, like this. The two behavioral
knobs, `reject_undeclared_inputs` and `reject_opaque_exposed_values`, are also settable **per tool** via `configure(:openapi)`, matching axn-mcp's convention. The per-class value wins
over the gem-wide one, so one endpoint can differ without loosening (or tightening) the whole API:

```ruby
class ListOwners
  include Axn
  tool :openapi

  configure(:openapi) do |c|
    c.reject_undeclared_inputs = true          # strict inbound, just for this endpoint
    c.reject_opaque_exposed_values = false     # tolerate a legacy exposed value
  end
  # ...
end
```

An override is honored by the generated document as well as at runtime: a tool with
`reject_undeclared_inputs = true` publishes `additionalProperties: false` on *its* request schema only,
so generated clients and OpenAPI validators match what the endpoint actually enforces.

The remaining settings are gem-wide only — `path_prefix` / `spec_path` / `tool_roots` describe the
mount and the registry rather than a tool, and the `info_*` values describe the one document.

## Rejecting opaque exposed values (`reject_opaque_exposed_values`)

When a successful result's `exposes` values are serialized into the response body, most values have an
obvious JSON form (a `String`, a `Hash`, a `Data.define`, …). But an exposed value can be **opaque** —
it has no JSON rendering *its author declared*, so it falls back to a generic one that leaks Ruby
internals: a bare object serializes to the string `"#<User:0x000055…>"`, and in a Rails app
ActiveSupport's generic `as_json` instead dumps the object's instance variables. Concretely, a value is
opaque when its only `to_s` is the one inherited from `Object` and it defines no `to_h`/`to_hash`/custom
`as_json` — i.e. it never told the serializer how it wants to look as JSON.

`reject_opaque_exposed_values` decides what happens when that occurs:

- **`true` (default)** — serialization raises
  `Axn::Extensions::Serialization::UnserializableValue` (naming the exact path, e.g.
  `records[3].owner`), which the dispatcher logs and maps to a generic 500 rather than publishing
  the blob.
- **`false`** — the opaque rendering ships in the response body.

**This default is the opposite of axn-mcp's**, deliberately. An MCP tool result goes to an LLM, where
an ugly-but-honest string usually beats a failed call; an OpenAPI response is a *published contract*
with a declared `output_schema`, and `"#<User:0x…>"` matches no schema and leaks internals to every
consumer. Same knob, same name, different default per transport.

Hash **keys** are held to the same standard: `serialize_value` renders keys via `#to_s`, so an opaque
key would become a garbage JSON *property name*.

Set it **gem-wide** (`Axn::OpenAPI.config.reject_opaque_exposed_values = false`) or **per tool** — see
[Per-tool overrides](#per-tool-overrides) — which lets one legacy endpoint opt out without loosening the
contract for the whole API.

### Values that are always rejected

`reject_opaque_exposed_values` is narrow: it toggles only the extra "was this rendering
author-declared?" test. Serialization itself is owned by axn core
(`Axn::Extensions::Serialization.render`), which unconditionally refuses values that have no
**honest** JSON form at all — turning the setting off does **not** buy these back, because the
alternative is a body `JSON.generate` refuses or one that silently lost data:

- a self-referential container (a cycle has no JSON representation);
- two Hash keys — or two exposed field names — that stringify to the same JSON property, which would
  collapse into one and silently drop a value;
- a non-finite `Float` (`Infinity`/`NaN`), including one reached by coercing a `BigDecimal`/`Rational`
  — JSON has no literal for them;
- a `String` whose bytes have no UTF-8 rendering (JSON is a UTF-8 format), whether it came from an
  exposure, a `Symbol`, or any `#to_s` you wrote.

Each raises `Axn::Extensions::Serialization::UnserializableValue`, naming the path to the offending
value (e.g. `records[3].price`), which this gem logs and maps to the generic 500 below.

## Status codes

The gem returns real HTTP status codes rather than a JSON-RPC-style `{ok: false, ...}` envelope —
status carries meaning, which is friendlier to curl/frontends/OpenAPI tooling than parsing a body to
find out whether a call succeeded.

| Code | When | Body |
| --- | --- | --- |
| `200` | Success | Bare `output_schema` object — the Axn's `exposes`, no wrapper |
| `400` | Malformed JSON request body, **or** an inbound validation failure (`InboundValidationError`) — "you sent the wrong data" | `{"error": {"message": "...", "field_errors": [...]}}` |
| `401` | Authentication failed — no or a wrong credential (checked before routing, so any path on an authenticated mount). Carries the strategies' `www-authenticate` challenge | `{"error": {"message": "Unauthorized"}}` |
| `403` | An authenticated principal not allowed to call this tool (`allowed_callers` / `authorize:`) | `{"error": {"message": "Forbidden"}}` |
| `404` | Path maps to no registered tool, **or** a known tool at an unregistered version — mount skin only. The latter's message names the latest available version's path | `{"error": {"message": "..."}}` |
| `405` | Known tool path, wrong HTTP verb — every route is `POST` (mount skin only) | `{"error": {"message": "..."}}` |
| `422` | A well-formed request the Axn itself refused via `fail!` — "we understood you, but can't complete the operation" | `{"error": {"message": "<the fail! message, verbatim>"}}` |
| `500` | An unexpected exception, or an unserializable exposed value on an otherwise-successful result (see [Values that are always rejected](#values-that-are-always-rejected) and `reject_opaque_exposed_values`) — generic message, no internal detail leaked | `{"error": {"message": "Internal Server Error"}}` |

> **Validation → 400, business `fail!` → 422 is intentional, not an oversight.** It runs against the
> common Rails/FastAPI reflex of "422 = validation failed." Here, `422` keeps its literal RFC 9110
> meaning: the request was well-formed and understood, but the operation was refused (a `fail!`).
> `400` means the *request itself* was bad (unparseable JSON, or a caller-supplied field failed
> validation). There's no third status that fits a `fail!` better — `400` can't describe a
> well-formed request being refused, and no other code carries a cleaner match — so this asymmetry
> is the deliberate design, not something to "fix" by moving `fail!` to `400` or validation to `422`.

## Response shapes

**Success is bare.** The body *is* the `output_schema` object — the Axn's `exposes`, at the top
level, no `data`/`result` wrapper. The HTTP status already carries ok/not-ok, so a top-level
`ok: true` would just duplicate the status line.

```json
{ "status": "approved" }
```

**Failure is a real envelope.** A failed Axn has no `output_schema` to honor (`exposes` aren't
populated on failure), so failure needs its own declared shape — a shared `Error` component in the
generated spec:

```json
{ "error": { "message": "Loan already decided" } }
```

A `400` additionally carries `field_errors`:

```json
{
  "error": {
    "message": "loan_id is required",
    "field_errors": [{ "field": "loan_id", "message": "is required" }]
  }
}
```

## Generating the spec directly

```ruby
Axn::OpenAPI.spec(mount: nil, tools: nil, auth: nil, authorize: nil, info: nil, path_prefix: nil)
# => the OpenAPI 3.1 document as a Hash (tools: defaults to Axn::OpenAPI.tools(mount:))
```

Pass `auth:` (and `authorize:`) to document security exactly as `.app` would:

- `components.securitySchemes` holds one entry per strategy.
- A top-level `security` lists them as alternatives.
- Every operation documents `401`.
- `403` is documented wherever a tool declares `allowed_callers`, or on every operation when
  `authorize:` is given.
- Without `auth:`, no security is documented.

One `POST` path per tool *version* (`/{tool}/v{n}`; `operationId` is `{tool}_v{n}`, `summary` from
`description`), `requestBody`/`200` schemas taken verbatim from that version's own
`input_schema`/`output_schema`, and `400`/`422`/`500` responses referencing the shared `Error`
component. A non-empty `semantic_hints` declaration is emitted as the `x-axn-semantic-hints` vendor
extension (an array).

## Requirements

- Ruby >= 3.2.1
- [axn](https://github.com/teamshares/axn) — the prerelease that ships `Axn::Extensions::Auth` (see the gemspec), < 0.2.0
- [rack](https://github.com/rack/rack) >= 2.2

## Development

- `bin/setup` — install dependencies (and the Rails dummy app's, if present).
- `bin/refresh` — pull latest and install dependencies (fails on a dirty working tree).
- Before pushing: `bundle exec rake` runs the Rails-free specs + rubocop; run `bundle exec rake
  verify` to also run the Rails dummy-app suite (`spec_rails`) — required for any Rails-affecting
  change.

Working on this gem with a coding agent? Read [`AGENTS-consuming.md`](AGENTS-consuming.md) for a
concise usage guide, or [`AGENTS.md`](AGENTS.md) if you're modifying the gem itself (`CLAUDE.md` is
a symlink to it).

## License

Released under the [MIT License](LICENSE.txt).
