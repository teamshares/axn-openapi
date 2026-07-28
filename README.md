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
  mount Axn::OpenAPI.app => "/api"
end
```

`Axn::OpenAPI.app` defaults to every registered `:openapi` tool. **The mount point is the path
prefix** — `mount ... => "/api"` means `ApproveLoan` is served at `POST /api/approve_loan/v1`, and
the generated spec at `GET /api/openapi.json`. Every route is versioned: the path is
`{mount}{path_prefix}/{tool}/v{n}`, where `n` is the Axn's `tool_version` (undeclared ⇒ `1`). There
is no bare, default, or "latest" path — a second version added later (`tool_version 2` on another
Axn sharing the same `tool_name`) is addressable at its own `/v2` path alongside the existing `/v1`,
never in place of it. `curl`:

```bash
curl -X POST http://localhost:3000/api/approve_loan/v1 -d '{"loan_id": 42}'
# => {"status":"approved"}

curl http://localhost:3000/api/openapi.json
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
Axn::OpenAPI.app(tools: nil, context: nil, path_prefix: nil, spec_path: nil)
```

- **`tools:`** — defaults to `Axn::OpenAPI.tools` (every registered `:openapi` tool); pass an
  explicit array (`[ApproveLoan, RejectLoan]`) to serve a subset.
- **`context:`** — `->(env) { {...} }`, resolved per-request into the trusted `ambient_context` (see
  [below](#ambient_context-the-authrequest-context-seam)). Defaults to an empty Hash.
- **`path_prefix:`** / **`spec_path:`** — override the configured defaults for this app instance.

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

## `ambient_context`: the auth/request-context seam

Axns don't know about HTTP, sessions, or `current_user` — those are request-scoped, and a plain
Axn should stay callable outside a request entirely. `ambient_context` is the seam: a Hash of
trusted, request-derived values that flows into the Axn's own `expects ..., on: :ambient_context`
fields, same as any other adapter (`axn-mcp`, `axn-ruby_llm`) uses.

**This gem offers the hook; it does not own auth.** It never authenticates a request itself — you
decide what goes into `ambient_context` (via `App#context` or the `ambient_context:` kwarg to
`render_axn`), typically after your own auth/session middleware has already run.

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

# Mount skin — read a header/session value per request:
Axn::OpenAPI.app(context: ->(env) { { approver_id: env["rack.session"]["user_id"] } })

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

`Axn::OpenAPI.tools` (`Axn.tools_for(:openapi, all_versions: true)`) enumerates the current
membership across every declared version of each tool — the default source for `.app`/`.spec`
when you don't pass an explicit `tools:` list.

## Configuration

```ruby
Axn::OpenAPI.config.path_prefix = "/axns"
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `path_prefix` | `""` | Prepended to every tool route when computing the spec's paths and (for the mount skin) when matching an inbound request. Purely cosmetic when mounting — the mount point (`mount ... => "/api"`) already does the real prefixing at the Rack level. |
| `spec_path` | `"/openapi.json"` | Where the mount skin serves the generated OpenAPI document (`GET`). |
| `reject_undeclared_inputs` | `false` (lenient) | `false`: unknown top-level body keys are silently ignored (matches JSON Schema's `additionalProperties`-permitted posture; forward-compatible across client/server version skew). `true`: an unknown key fails as a 400, same bucket as any other input-contract violation. A typo on a *required* field always fails regardless of this setting. |
| `strict_serialization` | `true` (strict) | `true`: an exposed value with no meaningful JSON projection (no own `as_json`/`to_h`, only the inherited `Object#to_s`) is a 500 — shipping `"#<User:0x...>"` in a published HTTP contract is a bug. `false`: falls back to `#to_s`, matching MCP's leniency (output there goes to an LLM, not a strict published contract). |
| `info_title` | `"Axn API"` | OpenAPI `info.title`. |
| `info_version` | `"1.0.0"` | OpenAPI `info.version`. |
| `info_description` | `nil` | OpenAPI `info.description`; omitted from the document when nil. |
| `tool_roots` | `%w[agent_tools]` | Directory roots granting implicit `:openapi` membership (see above). Validated: a broad entry (`app`, `.`, `actions`, a `..` traversal) is rejected. |

## Status codes

The gem returns real HTTP status codes rather than a JSON-RPC-style `{ok: false, ...}` envelope —
status carries meaning, which is friendlier to curl/frontends/OpenAPI tooling than parsing a body to
find out whether a call succeeded.

| Code | When | Body |
| --- | --- | --- |
| `200` | Success | Bare `output_schema` object — the Axn's `exposes`, no wrapper |
| `400` | Malformed JSON request body, **or** an inbound validation failure (`InboundValidationError`) — "you sent the wrong data" | `{"error": {"message": "...", "field_errors": [...]}}` |
| `404` | Path maps to no registered tool, **or** a known tool at an unregistered version — mount skin only. The latter's message names the latest available version's path | `{"error": {"message": "..."}}` |
| `405` | Known tool path, wrong HTTP verb — every route is `POST` (mount skin only) | `{"error": {"message": "..."}}` |
| `422` | A well-formed request the Axn itself refused via `fail!` — "we understood you, but can't complete the operation" | `{"error": {"message": "<the fail! message, verbatim>"}}` |
| `500` | An unexpected exception, or a `strict_serialization` violation on an otherwise-successful result — generic message, no internal detail leaked | `{"error": {"message": "Internal Server Error"}}` |

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
Axn::OpenAPI.spec(tools: nil, path_prefix: nil, info: nil)
# => the OpenAPI 3.1 document as a Hash (tools: defaults to Axn::OpenAPI.tools)
```

One `POST` path per tool *version* (`/{tool}/v{n}`; `operationId` is `{tool}_v{n}`, `summary` from
`description`), `requestBody`/`200` schemas taken verbatim from that version's own
`input_schema`/`output_schema`, and `400`/`422`/`500` responses referencing the shared `Error`
component. A non-empty `semantic_hints` declaration is emitted as the `x-axn-semantic-hints` vendor
extension (an array).

## Requirements

- Ruby >= 3.2.1
- [axn](https://github.com/teamshares/axn) >= 0.1.0-alpha.4.3, < 0.2.0
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
