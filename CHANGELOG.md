# Changelog

## Unreleased

> **Before cutting a release:** these changes need `Axn::Extensions::Auth`, which is on axn `main` but not in a released axn yet. Raise the gemspec `axn` floor to the release that ships it (alpha 7, PRO-3301) and drop the temporary `gem "axn", git: …` pins in `Gemfile` and `spec_rails/dummy_app/Gemfile`.

- `[FEAT]` Contract-test helper for consumers: `require "axn/openapi/testing"` (plain methods) or `"axn/openapi/testing/rspec"` (matchers). It is opt-in and backed by `json_schemer`, which the consumer adds to its test group; it isn't a runtime dependency. A missing `json_schemer` raises `Axn::OpenAPI::Error` saying so.
  - `be_a_valid_openapi_document` / `Testing.document_errors(doc)`: the OpenAPI 3.1 metaschema, then each declared `request_example` / `response_example` against its operation's schema.
  - `match_openapi_response(doc, operation_id:, status: nil)` / `Testing.response_errors(...)`: a body against the response schema the operation documents for that status, resolving the shared `Error` `$ref`. It takes a response object (reading its `status`) or a bare Hash/JSON body with `status:`. An unknown operation or undocumented status is reported as an error, not skipped.
  - `validate_document!` / `validate_response!` raise `Axn::OpenAPI::Testing::ContractViolation`.
  - `[INTERNAL]` The gem's own suite now uses these matchers.
- `[FEAT]` The document is also available as YAML.
  - `Axn::OpenAPI.spec_yaml(...)` takes `.spec`'s arguments and returns a YAML String. Keys are Strings, exactly as a JSON client receives them, via a JSON round-trip, so no Ruby `:symbol` keys leak.
  - A mount serves it at the new `spec_yaml_path` setting (default `"/openapi.yaml"`, `nil` turns it off) as `application/yaml`. It's authenticated like `spec_path`, including the `public_spec:` exemption, and is GET-only (a JSON 405 + `Allow: GET` otherwise).
  - Build time fails if it collides with a tool route or with `spec_path`.
  - If building the document raises (JSON or YAML), the mount now answers the generic 500 and logs the error, instead of raising out of the Rack app.
  - `[INTERNAL]` `Dispatch` gains a `format` member (`:json` by default; existing positional construction is unchanged), rendered by the new `Response.for`.
- `[FEAT]` Four per-tool documentation settings, set via `tool openapi: { … }` or `configure(:openapi)`. They shape only the published document.
  - `operation_tags` (non-empty Array of Strings) → the operation's `tags`, plus a top-level `tags` list naming each once. Not called `tags`, to avoid confusion with axn's `tag` telemetry DSL.
  - `deprecated`: **automatic by default.** A tool version is published `deprecated: true` when the same document also carries a newer version of that tool; `true`/`false` forces it. Judged per document, so a mount serving only v1 doesn't mark it. Documents that already serve several versions of a tool now mark the older ones deprecated.
  - `request_example` / `response_example` (a Hash) → the request body's / `200`'s `examples.default`, JSON-shaped, a fresh copy per document. An example with no JSON rendering (a NaN, a cycle, invalid bytes) is refused at declaration. Conformance to the schemas isn't checked at runtime (see the contract-test helper).
- `[BUGFIX]` A mount no longer buffers the request body before authenticating it (flagged in the PRO-3566 security review).
  - **Old:** `Request.from_rack` read `rack.input` in full up front, so an anonymous request bound for a 401 still had its whole body read into memory. **New:** `Request#raw_body` reads it on first call, memoized. The App reads it only when a tool is actually dispatched, so 401/403/404/405 and spec-document requests never touch it.
  - A strategy that needs the body (a signature check, say) can still call `request.raw_body` during authentication; dispatch reuses that read.
  - `Request#inspect` doesn't force the read. It shows the body's byte size only once the body has been read.
  - `Request.new(raw_body: "…")` is unchanged. The internal `Router#route` now also accepts a zero-arity callable for `raw_body:`.
- `[FEAT]` New `Axn::OpenAPI.config.path_segment_style` (`:snake` by default, or `:kebab`), for apps whose route convention is kebab-case.
  - `:kebab` serves a multi-word tool at `/list-integrations/v1` instead of `/list_integrations/v1`. Only the URL segment changes; `tool_name` and `operationId` (`list_integrations_v1`) stay snake_case.
  - An app captures the style when it's built, so its routing and its served document can't drift apart.
  - A 404 for an unknown version names the tool by its rendered segment and points at that segment's latest path.
- `[BREAKING]` `Axn::OpenAPI.app` / `App.new` now **require `auth:`**. The gem is fail-closed.
  - **Old:** omitting it served unauthenticated. **New:** omitting it raises `Axn::OpenAPI::Error` at build time.
  - Pass a strategy (`Axn::Extensions::Auth::Bearer.new(keys: {...})` from axn core), an Array of
    strategies (any of them may authenticate), or `auth: :none` to serve unauthenticated explicitly.
- `[BREAKING]` `Axn::OpenAPI.tools` is now mount-filtered: `tools(mount: nil)`.
  - **Old:** it listed every `:openapi` tool. **New:** it lists only the tools bound to the given
    mount, and the default (nil) mount excludes any tool declaring `tool openapi: { mount: ... }`.
  - `.app` and `.spec` default their tools the same way.
- `[BREAKING]` A mount's `context:` is now evaluated lazily, and may take the principal.
  - **Old:** it ran on every request, including 404/405/spec-document requests. **New:** it runs
    only when a tool is actually dispatched.
  - A two-parameter `context: ->(env, principal)` receives the authenticated principal. A
    one-parameter `->(env)` works as before. Detection reads the callable's `parameters`, not its
    arity: one that can take a second positional argument (required, optional, or a splat) gets
    the principal, so `->(env = nil)` / `def call(env = nil)` still receive the env alone.
- `[BREAKING]` Changes to the internal `Router`'s interface:
  - It now maps a path to its `RouteEntry` rather than to the bare Axn.
  - `#route` takes `authorize:`, and accepts a callable `ambient_context:`.
  - It gains `#spec_path?`.
- `[FEAT]` Authentication runs before routing. An unauthenticated request gets
  `401 {"error":{"message":"Unauthorized"}}` on every path, including unknown ones, so tool
  existence can't be probed. The 401 carries each strategy's `www-authenticate` challenge (merged
  when there are several).
  - The served OpenAPI document is gated the same way unless the mount passes `public_spec: true`.
  - A strategy that raises (a misconfigured secret) is answered with the generic 500 and reported,
    never a 401.
  - The authenticated principal is stored at `env["axn.openapi.principal"]`
    (`Axn::OpenAPI::PRINCIPAL_ENV_KEY`).
- `[FEAT]` A per-tool 403 allowlist: `tool openapi: { allowed_callers: ["data_pipeline"] }` (a new
  overridable setting that takes a non-empty Array of String/Symbol principal ids).
  - An authenticated caller not on the list gets `403 {"error":{"message":"Forbidden"}}`. The check
    runs before the 405 verb check.
  - A mount's `authorize: ->(principal, axn_class) { bool }` replaces the default check, which is
    public as `Axn::OpenAPI.allowed_caller?`. The policy's answer is read `ok?`-first, like a
    strategy's verdict, so a denying `Axn::Result` or `Auth::Verdict` denies instead of passing as a
    truthy object.
  - A 404 never points a forbidden caller at a tool's latest version: it gets the same message as a
    nonexistent tool. An `authorize:` policy that raises is answered with the generic 500 on a
    version miss too, just as on a real route, rather than being masked as that 404.
  - Build time raises for an `allowed_callers` tool or `authorize:` on an `auth: :none` mount, and
    for an `allowed_callers` entry none of the mount's strategies can authenticate as. That check is
    skipped when a strategy can't enumerate its principals.
  - The controller skin enforces the same allowlist: `render_axn(..., principal:)` returns a 403 on
    refusal. Calling it without `principal:` on an allowlisted tool raises, rather than silently
    failing open.
- `[FEAT]` Named mounts: `tool openapi: { mount: :credentials }` (a new overridable setting that
  takes a Symbol) binds a tool to `Axn::OpenAPI.app(mount: :credentials, …)` and keeps it off every
  other mount.
  - An explicit `tools:` entry that declares a different mount raises.
  - That declaration is the isolation guarantee; there is no process-wide registry of built mounts,
    so building a mount twice or listing an undeclared tool on two ad-hoc mounts is served as
    written, and Rails route reloads need no special handling. The gem ships no Railtie.
  - `render_axn` refuses a mount-bound tool unless it is passed the matching `mount:`, so a
    controller can't serve a mount's tool past that mount's auth by accident. That `mount:` also
    labels the controller's `Authorize` event, so a controller denial is recorded under its mount
    rather than `default`.
  - Each mount takes its own `info:` (merged over `info_*`).
- `[FEAT]` The generated document describes the mount's auth: `components.securitySchemes` plus a
  top-level `security` that lists the strategies as alternatives.
  - A `Bearer` strategy is documented as `http`/`bearer`, or as `apiKey` for a custom `header:`.
    Wrap any other strategy (e.g. an app-side JWT verifier) with
    `Axn::OpenAPI.documented_auth(strategy, security_scheme: {...}, name:)`. A strategy the gem can't
    describe is refused at build time. A documented `http` scheme whose strategy supplies no 401
    challenge gets the one the scheme implies (`WWW-Authenticate: Bearer` for `scheme: "bearer"`),
    so its 401s carry the challenge RFC 9110 requires. The strategy's own challenge still wins.
  - Every operation documents `401`. `403` is documented where the tool has `allowed_callers`, or
    everywhere when the mount has `authorize:`.
  - `Axn::OpenAPI.spec` accepts `mount:`, `auth:` and `authorize:` to produce the same document.
- `[FEAT]` Authentication and authorization run as Axns (`Axn::OpenAPI::Authenticate` /
  `Axn::OpenAPI::Authorize`), following the pattern of axn-webhooks' `Verify` stage. Every
  request, including a 401/403 that never reaches a tool, emits core's `axn.call`
  event/span/log with `mount` and `reason` dimensions and `principal` and `operation_id` tags.
  - A non-String principal is recorded only by its class name.
  - The presented credential is never logged: the gate's inputs are `sensitive:`, and the new
    `Request#inspect`/`pretty_print` redact headers and body.
- `[FEAT]` `Axn::OpenAPI::Request` now carries case-insensitive `headers` / `#header(name)`, which is
  the interface core's auth strategies read.
- `[BUGFIX]` HTTP tool calls are now stamped `invoked_via: openapi`. The Dispatcher now passes
  `adapter: :openapi` to `Axn::Tools::Invoker`; before, OpenAPI traffic carried no entry-point
  dimension, unlike axn-mcp/axn-ruby_llm.
- `[INTERNAL]` The generated documents are validated against the OpenAPI 3.1 metaschema in the suite
  (`json_schemer` dev dependency).
- `[INTERNAL]` The Rails dummy app is bumped to Rails 8.1 (`load_defaults 8.1`), since axn requires
  activesupport >= 8.1. It also gains a Bearer-gated `:credentials` mount plus controller coverage.

- `[INTERNAL]` Cuts over to axn core's `Axn::Tools::AdapterSerialization` mixin (PRO-2996, shipped in
  `0.1.0-alpha.6`, which the gemspec floor is raised to accordingly). `declare_reject_opaque_exposed_values!
  default: true` replaces the hand-rolled `setting :reject_opaque_exposed_values, ...` (still `true`
  gem-wide, still `overridable:` — this gem's default stays the odd one out vs. axn-mcp/axn-ruby_llm's
  `false`), `tool_roots_default %w[agent_tools]` replaces the hand-rolled `setting :tool_roots, ...`
  (same default, same `Axn::Tools::AdapterRoots.validate!` broad-path guard), and `Dispatcher#success`
  now renders via `Axn::OpenAPI.serialize_exposed(result)` instead of resolving the override and calling
  `Axn::Extensions::Serialization.render` itself. No public API changes and no behavior change on their
  own — same settings, same defaults, same resolve-then-render chain, just the shared implementation
  every tool-adapter gem was duplicating. See the `[FEAT]` entry below for the one deliberate behavior
  change this cutover enables.
- `[FEAT]` A failed success-serialization (an exposed value with no honest JSON representation, or an
  exception raised by a value's own `as_json`/`to_h` projection) now reports through
  `Axn.config.on_exception` and re-raises instead of returning a 500 when
  `Axn::Extensions.raises_in_dev?` is true — matching how every other guarded step in axn behaves.
  Previously this gem's dispatcher was the one adapter that swallowed this failure into a log line and
  a generic 500 with no `on_exception` report and no dev-loud raise, regardless of environment; that gap
  is exactly the defect class PRO-2996's acceptance criteria calls out (every adapter's tool-response
  guard must report + honor `raises_in_dev?`), so treat this as a bugfix if you'd rather file it there.
  Comes from routing `Dispatcher#success`'s render step through
  `Axn::OpenAPI.guard_tool_response` (the same `Axn::Tools::AdapterSerialization` mixin) instead of a
  bare `rescue`. The response shape is unchanged (still a generic 500 with the same operator log hint
  outside of dev), and the separate `#ensure_encodable` guard over the final `JSON.generate` re-encode
  step is untouched — it covers a different failure point and still only logs.
- `[FEAT]` `Axn::OpenAPI::Error` now `include`s `Axn::Error`, core's public-error boundary marker
  (axn [#216](https://github.com/teamshares/axn/pull/216) / PRO-2997), so a caller wrapping a mount
  or a `render_axn` call catches axn's errors and this adapter's with one `rescue Axn::Error`.
  `Axn::Error` is a module, not a base class, so the ancestry is unchanged — `Axn::OpenAPI::Error`
  is still a `StandardError` and anything already rescuing that keeps working. The tag is inherited,
  so subclasses are covered too. Shipped in axn `0.1.0-alpha.5`, this gem's dependency floor.
- `[INTERNAL]` Tracks axn core's tool-surface move in
  [#213](https://github.com/teamshares/axn/pull/213) / PRO-3005: `Axn.tools_for` → `Axn::Tools.for`
  and `Axn.register_tool_adapter` → `Axn::Tools.register_adapter`. Core ships no aliases, so this
  gem raises at `require` time below its axn floor of `0.1.0-alpha.5`. No public surface of this gem
  changes —
  `Axn::OpenAPI.tools` still returns every declared version of every registered `:openapi` tool, and
  registration still happens at load. If you called `Axn.tools_for(:openapi, ...)` directly, call
  `Axn::Tools.for(:openapi, ...)` instead.
- `[INTERNAL]` Success bodies now render through axn core's declared adapter entry point,
  `Axn::Extensions::Serialization.render(result, reject_opaque:)` — see axn
  [#207](https://github.com/teamshares/axn/pull/207) / PRO-2992, which made
  the old `serialize_exposed` private and derives the declared `exposes` configs from the result
  itself, so there is no `field_configs` argument to pass. No behavior change: the same code renders
  the same bodies and raises the same `Axn::Extensions::Serialization::UnserializableValue`. With
  `field_configs` gone, `Axn::OpenAPI::Serializer` had nothing left to do that core's facade wasn't
  already doing under a better name, so the module is **removed** and `Dispatcher#success` calls
  `render` directly. It was public but undocumented (the README documents the *setting*, never the
  module); if you called `Serializer.serialize(result, configs, reject_opaque:)` yourself, call
  `Axn::Extensions::Serialization.render(result, reject_opaque:)` instead.
- `[BUGFIX]` A request body with invalid UTF-8 is now rejected as a malformed-body `400` (JSON must be
  UTF-8 per RFC 8259). Previously a bad object key (e.g. `{"\xFF":1}`) survived parsing and blew up in
  key symbolization — before any `Dispatch` existed, so it escaped the render-boundary encode gate.
- `[BUGFIX]` The JSON-encodability gate now runs at each skin's render boundary, so it covers EVERY
  response body — the mount router's 404s (which are request-path-derived) and the generated spec
  document included, not just `Dispatcher.call`'s. An unencodable body (e.g. invalid UTF-8 from a
  request path) maps to the generic 500 instead of raising out of the renderer. Relatedly, the 404
  "unknown tool" body no longer echoes the raw request path (untrusted, possibly invalid-UTF-8 input).
- `[BREAKING]` The `strict_serialization` setting is now **`reject_opaque_exposed_values`** (same `true`
  default), and every "this exposed value has no honest JSON representation" check is delegated to axn
  core's `Axn::Extensions::Serialization.render(reject_opaque:)` — see axn
  [#206](https://github.com/teamshares/axn/pull/206) / PRO-2988, shipped in `0.1.0-alpha.5`, which the
  gemspec floor is raised to accordingly. The new name is axn-mcp's, reused verbatim so one concept has
  one name across the adapter family: it names *what it rejects* (rather than a vague `strict:`, which
  would wrongly imply the non-rejected output might not be JSON) and qualifies it with `exposed` so it
  is unambiguously about outbound `exposes` serialization, not inbound `coerce:`. Also `overridable:`,
  again matching axn-mcp — a single tool can opt out via
  `configure(:openapi) { |c| c.reject_opaque_exposed_values = false }` without loosening the whole API,
  and the per-class value wins over the gem-wide one. This gem no longer walks the value graph itself, and
  `Axn::OpenAPI::UnserializableExposureError` is **removed** in favor of core's
  `Axn::Extensions::Serialization::UnserializableValue` (an `ArgumentError`, which also names the
  offending field path). Rescue that instead if you referenced the old class. Behavior changes worth noting:
  - Rejections split into two tiers. `reject_opaque_exposed_values` governs only values that would
    render *honestly but unpresentably* — a value or Hash key whose only `to_s` is the inherited
    `Object#to_s`, or (in Rails) whose only `as_json` is ActiveSupport's generic one. Values
    with no JSON rendering **at all** are now rejected regardless of the setting, because the
    alternative is a body `JSON.generate` refuses or one that silently lost data: a cycle, two Hash
    keys (or two exposed field names) that collapse to one JSON property, a non-finite `Float`
    (including via `BigDecimal`/`Rational` coercion), or a `String` whose bytes have no UTF-8
    rendering. Previously `strict_serialization = false` let several of these through to the encode
    gate (or, for the collapse case, to a silently-lossy `200`).
  - **In a Rails app, `reject_opaque_exposed_values` now also rejects a value whose only `as_json` is
    ActiveSupport's generic `Object#as_json`** (one declaring no `as_json`, `to_h`, or `to_hash` of
    its own). That
    generic implementation dumps instance variables, so such a value previously passed strict mode and
    returned a `200` whose body leaked internals and matched no declared schema; it is now a `500`.
    Give the value its own `as_json`/`to_h`, or declare it `type: String` and format it.
  - The "disable with …" pointer moved out of the exception message into the dispatcher's `500` log
    line: core raises the same error for adapters that have no such setting, so it must not name this
    gem's config knob.
- `[FEAT]` `reject_undeclared_inputs` is now `overridable:` too, so **both** behavioral knobs are
  settable per tool via `configure(:openapi)` (the per-class value wins over the gem-wide one) —
  consistent with each other and with axn-mcp. Both also gain `one_of: [true, false]`, which rejects a
  non-boolean assignment at write time instead of letting a truthy `"false"` silently invert the intent.
  Note the override is honored by **both** readers of the setting: `SpecGenerator` resolves it per tool
  as the `Dispatcher` does, so a tool that opts in publishes `additionalProperties: false` on its own
  request schema only — a per-tool override the document ignored would send generated clients a payload
  the endpoint then 400s (the same spec-vs-runtime drift an earlier entry below fixed gem-wide).
- `[BUGFIX]` `Axn::OpenAPI::App` dups + freezes the resolved `path_prefix`, so mutating the source
  String after construction can't drift the prefix captured by the spec provider away from the
  router's route map.
- `[BUGFIX]` The mount router fails loud at construction if `spec_path` collides with a tool route
  (which would otherwise shadow the tool — GET serving the doc, POST 405ing — while the doc still
  advertised the tool there).
- `[BUGFIX]` The 404 "unknown version" pointer now includes the Rack mount base (`SCRIPT_NAME`), so it
  names the real externally-visible URL (e.g. `/api/greeter/v2`) instead of the mount-relative
  `/greeter/v2` (which would 404 at the origin root).
- `[BUGFIX]` Each generated OpenAPI document now gets an independent `Error` component schema (built
  fresh per `generate`, not a shared shallow-frozen constant), so a caller mutating one returned
  document can't contaminate later `.spec` results or already-served app documents.
- `[BUGFIX]` When `reject_undeclared_inputs` is enabled, the generated request schemas now set
  `additionalProperties: false`, so OpenAPI validators / generated clients match the runtime (which
  400s unknown top-level fields). Left permissive in the default lenient mode.
- `[BUGFIX]` `405 Method Not Allowed` responses now carry the required `Allow` header — `POST` for a
  tool path, `GET` for the spec endpoint — so clients can discover the supported method. (`Dispatch`
  gained an optional `headers` member to carry it; the Rack app forwards it.)
- `[BUGFIX]` `spec_provider:` supports both a zero-arg `-> { ... }` (the documented form) and a
  one-arg `->(script_name) { ... }` provider — the router adapts on arity, reading it correctly for
  Procs/lambdas/Methods AND plain callable objects (`def call`). (Threading `SCRIPT_NAME` to the
  provider had briefly broken the zero-arg form.)
- `[BUGFIX]` `Axn::OpenAPI::App` snapshots the `tools:` array at build time (dup + freeze), so a
  caller mutating that array afterward can't split the router's build-time route table from the
  default spec provider's per-request regeneration (which would advertise a 404ing route, or hide a
  working one).
- `[BUGFIX]` `Axn::OpenAPI::App` resolves the `path_prefix` once at build time and hands the same value
  to both its router and its default spec generator. Previously a default (omitted) prefix was captured
  by the router but re-resolved by the generator per spec request, so mutating
  `Axn::OpenAPI.config.path_prefix` after an app was built could make it route at the old prefix while
  its served OpenAPI document advertised the new one.
- `[BUGFIX]` The served OpenAPI document now publishes the Rack mount base as a `servers` entry
  (`[{ "url": "<SCRIPT_NAME>" }]`) when the app is mounted below the origin root. The doc's `paths`
  are mount-relative, so without this a spec served at `/api/openapi.json` listed `/echo_tool/v1` with
  no server base and OpenAPI defaulted the server to `/`, sending generated clients / interactive
  tooling to the wrong root-level URL. Derived per-request from `SCRIPT_NAME`; a root mount omits
  `servers` (the `/` default is already correct). `SpecGenerator` gained a `servers_base:` argument.
- `[BUGFIX]` The controller mixin (`render_axn`) now rejects a malformed (or non-object) request body
  with a `400`, instead of silently treating it as `{}` — matching the mount router exactly. Both
  skins now share one body parser (`Dispatcher.parse_body`), so they can't diverge. Previously a tool
  with no required inputs would run and return `200` on garbage input via the controller.
- `[BUGFIX]` Hardened the serialization path against self-referential (cyclic) Array/Hash values, which
  would otherwise recurse to `SystemStackError`; the dispatcher's success boundary also catches
  `SystemStackError` (not a `StandardError`) as a backstop → generic `500`. Cycle detection itself now
  lives in axn core (see the `reject_opaque_exposed_values` entry above), which additionally guards the case this gem's
  own walk missed: a projection pointing back at its source (`def to_h = { child: self }`) recursed
  unboundedly here, because only the `Hash`/`Array` branch was guarded, never the `as_json`/`to_h`
  source object. Core guards the source object.
- `[BUGFIX]` Every Axn-derived response body — success exposures **and** the `fail!`/validation
  envelopes — now passes a single JSON-encodability gate in the dispatcher before it's returned, so
  an unencodable body (a non-finite number, or a `String` with invalid UTF-8 such as a `fail!` message
  carrying binary data from an upstream service) maps to the documented generic `500` instead of
  raising mid-render and escaping the Rack app / host framework. Previously only the success body was
  guarded; a bad `fail!`/validation message would have raised. Works regardless of `reject_opaque_exposed_values`;
  exceptions raised *during* serialization (projection errors, cycles) are still caught too. The gate
  is retained now that core guarantees no *value* `JSON.generate` refuses, because that is a promise
  about values rather than about encoder options — a body nested deeper than JSON's `max_nesting`
  still raises `JSON::NestingError` — and because it also covers bodies core never built, such as a
  router 404 or the generated spec document.
- `[BUGFIX]` Hash **keys** are validated, not just values: `serialize_value` stringifies keys via
  `#to_s`, so a key with only the default `Object#to_s` (which would render as garbage like
  `"#<User:0x…>"`) is rejected under `reject_opaque_exposed_values`, exactly as such a value is — and two keys that
  stringify to the same JSON property (e.g. `{ id: 1, "id" => 2 }`) are rejected unconditionally,
  since stringifying would silently collapse them and drop a value. Both now enforced by axn core.
- `[BUGFIX]` `SpecGenerator` now derives each operation's `requestBody.required` from the input
  contract (true only when the Axn has a required inbound field) instead of hardcoding `true`. An
  ambient-context-only tool (empty input schema) or an all-optional-input tool is now `required:
  false`, matching the router (which accepts a blank body as `{}`) — so OpenAPI validators and
  generated clients no longer reject a request that succeeds at runtime.
- `[FEAT]` `Axn::OpenAPI` (renamed from the scaffolded `Axn::Openapi`) is now `Axn::Configurable` +
  `Axn::Tools::AdapterRoots`, with settings `path_prefix` (`""`), `spec_path` (`"/openapi.json"`),
  `reject_undeclared_inputs` (`false`), `reject_opaque_exposed_values` (`true`), `info_title` (`"Axn API"`),
  `info_version` (`"1.0.0"`), `info_description` (`nil`), and `tool_roots` (`%w[agent_tools]` — an
  Axn under `app/agent_tools/` is served with no explicit `tool :openapi`, matching axn-mcp/
  axn-ruby_llm's convention). Registers `:openapi` as a tool adapter with axn core's process-global
  registry (`Axn::Tools.register_adapter(:openapi, self)`), so `Axn::Tools.for(:openapi)` enumerates
  directory-root and explicitly-declared (`tool :openapi`) tools.
- `[FEAT]` `Axn::OpenAPI::Dispatcher.call(axn_class:, params:, ambient_context: {})` is the spine all
  skins delegate to: it runs the Axn through core's `Axn::Tools::Invoker` and maps the returned
  `Axn::Result` to an `Axn::OpenAPI::Dispatch` (`Data.define(:status, :body)`) per the approved
  status scheme — 200 on success (body rendered by core's `Axn::Extensions::Serialization.render`),
  400 with `field_errors` on caller
  input-contract violations (`Invoker.input_invalid?`), 422 with the `fail!` message on a business
  failure, and a generic no-leak 500 on any other exception or on an
  `Axn::Extensions::Serialization::UnserializableValue` from serialization (logged via
  `Axn.config.logger.error`). `params` top-level keys are
  symbolized before the Invoker's `**` splat; nested Hashes are passed through as-is.
- `[FEAT]` `Axn::OpenAPI::Request` (`Data.define(:http_method, :path, :raw_body)`) is a
  Rails-agnostic view of an inbound HTTP request, with `.from_rack(env)` reading and rewinding
  `rack.input`. `Axn::OpenAPI::Router.new(tools:, path_prefix: nil, spec_path: nil,
  spec_provider: nil)` maps `#route(http_method:, path:, raw_body:, ambient_context: {})` to a
  `Dispatch`: strips the configured `path_prefix` (defaults from `Axn::OpenAPI.config`), serves
  `spec_provider.call` (defaults to `-> { {} }`; `App` wires a real `SpecGenerator` by default — see
  below) at `spec_path` on GET, looks tools up by `tool_name(:openapi)`, and owns the pre-dispatch
  HTTP-layer cases — 404 unknown tool, 405 wrong verb (including on the spec route), and 400 for a
  genuinely malformed non-empty JSON body or a parsed non-Hash JSON value (a blank body parses to
  `{}` and dispatches normally). All other requests delegate to `Dispatcher.call`.
- `[FEAT]` `Axn::OpenAPI::App.new(tools: nil, context: nil, path_prefix: nil, spec_path: nil,
  spec_provider: nil)` is a framework-agnostic Rack app (`#call(env)`) directly `mount`able in a
  Rails routes file (`mount Axn::OpenAPI::App.new(...) => "/api"`) or `run`-able in a bare
  `Rack::Builder`. Builds a `Request` from the Rack env, resolves `context.call(env)` (default
  `->(_env) { {} }`) into the trusted `ambient_context` — the auth seam the gem offers but does not
  own — and delegates to `Router#route`, rendering the resulting `Dispatch` via
  `Response.json(...).to_rack`. Adds `rack` (`>= 2.2`) as a runtime dependency.
- `[FEAT]` `Axn::OpenAPI::SpecGenerator.new(tools:, path_prefix: nil, info: nil).generate` assembles
  the OpenAPI 3.1 document `App`'s default `spec_provider` serves: one POST path per tool at
  `"#{path_prefix}/#{tool_name(:openapi)}"` (`path_prefix` defaults from `Axn::OpenAPI.config`),
  `operationId` = `tool_name(:openapi)`, `summary` = `description` (omitted when undeclared),
  `requestBody`/`200` schemas taken verbatim from `input_schema`/`output_schema`, and `400`/`422`/
  `500` responses all referencing a shared `#/components/schemas/Error` component. Non-empty
  `_semantic_hints` are emitted as the `x-axn-semantic-hints` vendor extension (an array — plural,
  since a tool can carry more than one hint). `info` defaults from `Axn::OpenAPI.config.info_*`
  (`info_description` omitted when nil).
- `[FEAT]` `Axn::OpenAPI::Controller` is the third skin: `include` it into a Rails (or any
  duck-typed `request`/`render`) controller for consumers who want to own their own routing/auth
  stack. `#render_axn(axn_class, ambient_context: {})` reads `request.raw_post`, parses it as JSON
  (blank or malformed body → `{}`, which surfaces downstream as a normal 400
  `InboundValidationError` if required fields are missing — the mixin has no dedicated 400
  parse-error envelope like `Router` does), delegates straight to `Dispatcher.call` (bypassing
  `Router` entirely since the controller owns routing), and renders `render json: dispatch.body,
  status: dispatch.status`. The module itself references no Rails constants at load time.
- `[FEAT]` Module-level facade: `Axn::OpenAPI.tools` (`Axn::Tools.for(:openapi, all_versions: true)`), `Axn::OpenAPI.app(
  tools: nil, context: nil, path_prefix: nil, spec_path: nil)` (builds an `App` over `tools:` or
  every registered tool), and `Axn::OpenAPI.spec(tools: nil, path_prefix: nil, info: nil)` (builds a
  `SpecGenerator` and calls `#generate`) — the one-liner public entry points that tie `App` and
  `SpecGenerator` to the tool registry, so a consumer never has to reach for `App.new`/
  `SpecGenerator.new` directly. Ships user-facing docs: a rewritten `README.md` (mount/controller
  usage, the config table, the full status-code table with an explicit note on the 400-vs-422
  design), and a new `AGENTS-consuming.md` (agent-facing usage guide, allowlisted into the gem
  package).
- `[FEAT]` `Axn::OpenAPI::RouteTable.build(tools:, path_prefix:)` is the single source of the
  tool→path map, ordered by `tool_name(:openapi)` then ascending `tool_version` (undeclared version
  defaults to `1`): one `Axn::OpenAPI::RouteEntry` (`Data.define(:path, :axn, :operation_id)`) per
  tool version, with `path` = `"#{path_prefix}/#{tool_name}/v#{tool_version}"` and `operation_id` =
  `"#{tool_name}_v#{tool_version}"`. `Axn::OpenAPI.tools` now returns `Axn::Tools.for(:openapi,
  all_versions: true)` (every declared version of each tool) instead of the latest-per-tool_name
  view, so a stable HTTP contract can eventually address every version at its own path. This task is
  additive scaffolding — `Router` and `SpecGenerator` don't consume `RouteTable` yet.
- `[BREAKING]` `Axn::OpenAPI::Router` now builds its dispatch map from `RouteTable` and matches only
  the full versioned path `{prefix}/{tool_name}/v{tool_version}` — the old bare `{prefix}/{tool_name}`
  path is gone, so every request (including single-version tools) must address a specific version
  (e.g. `POST /echo_tool/v1`). A request to a bare or otherwise unmatched path 404s. When the path is
  shaped like a tool call (`/{name}/v{n}`) and `{name}` is a real tool but `{n}` isn't a version it
  has, the 404 body points at the latest available version (`"Unknown version for tool 'calc'.
  Latest available: /calc/v2."`); when `{name}` isn't a known tool at all, the 404 just names it
  (`"Unknown tool: nope"`) with no version pointer. `Router.new(tools:, path_prefix:, spec_path:,
  spec_provider:)` and the spec-endpoint/405/400 behavior are unchanged. This is an intentional
  intermediate state: routes are now versioned, but `SpecGenerator`'s served document still
  advertises bare tool paths — a follow-up task flips the doc to match.
- `[INTERNAL]` Rails integration coverage in the `spec_rails/dummy_app`: `EchoTool`/`RefuseTool`
  fixtures under `app/agent_tools/` (Zeitwerk-autoloaded), a `LoansController < ActionController::API`
  exercising `Axn::OpenAPI::Controller#render_axn` with request-derived `ambient_context`, and routes
  mounting `Axn::OpenAPI.app(tools: [EchoTool])` at `/api` alongside `post "/loans/approve"`. A new
  `spec/openapi_integration_spec.rb` drives both skins over real HTTP via `Rack::Test` (no
  `rspec-rails`/`type: :request` in this dummy app): a mounted tool call, the mounted `/openapi.json`,
  and the controller mixin mapping `fail!` to 422.
- `[BREAKING]` `Axn::OpenAPI::SpecGenerator#generate` now builds `paths` from `RouteTable.build`
  instead of one bare `{path_prefix}/{tool_name}` entry per tool: it emits one path per tool
  *version* (`{path_prefix}/{tool_name}/v{tool_version}`), each keyed by its own `RouteEntry#path`
  and given a doc-unique `operationId` (`RouteEntry#operation_id`, `{tool_name}_v{tool_version}`)
  and its own version's `input_schema`/`output_schema`/`description`/`_semantic_hints`. This closes
  the gap the previous task left open — served routes (`Router`) and the documented OpenAPI paths
  now always agree, since both are derived from the same `RouteTable`. The old bare-path doc shape
  (one entry per tool name, latest version only) is gone.
- `[INTERNAL]` End-to-end multi-version proof in the Rails dummy app: `GreeterV1`/`GreeterV2` fixtures
  under `app/agent_tools/` share `tool_name` "greeter" via `axn_name "greeter"` (their class names
  would otherwise derive distinct `greeter_v1`/`greeter_v2` names) and declare `tool_version 1`/`2`
  respectively, each with its own `expects :subject`/`exposes :greeting` contract. Mounted alongside
  `EchoTool` at `/api`, they prove two coexisting versions of one *registered* tool serve distinct
  contracts at distinct paths (`/api/greeter/v1`, `/api/greeter/v2`), both appear in the served
  `/api/openapi.json`, and an unregistered version (`/api/greeter/v9`) 404s with a message pointing
  at the latest available version's path — all new `spec/openapi_integration_spec.rb` cases.
- `[INTERNAL]` `README.md`/`AGENTS-consuming.md` routing sections rewritten for the versioned URL scheme:
  every route is `{mount}{path_prefix}/{tool}/v{n}` (undeclared `tool_version` ⇒ `/v1`), there is no
  bare/default/latest path, the newest version is read from the served spec's `paths` (highest `vN`)
  rather than a dedicated route, and a 404 on a known tool's unregistered version names the latest
  available version's path. `AGENTS-consuming.md` additionally notes that declaring `tool_version N`
  on a second Axn sharing a `tool_name` (via `axn_name`) adds a `/vN` path without touching any
  existing version's path. Stale example paths (`/approve_loan` → `/approve_loan/v1`) updated
  throughout.
- `[BUGFIX]` `Axn::OpenAPI::App.new` with no explicit `tools:` now defaults to `Axn::OpenAPI.tools`
  (all versions of every registered tool) instead of `Axn::Tools.for(:openapi)` (latest version
  only). The old default meant `mount Axn::OpenAPI::App.new => "/api"` silently served only the
  newest version of any multi-version tool — the exact drift this gem's versioned-URL scheme
  exists to prevent.
