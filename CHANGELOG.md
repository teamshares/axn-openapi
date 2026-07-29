# Changelog

## Unreleased

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
  core's `Axn::Reflection::Values.serialize_exposed(reject_opaque:)` — see axn
  [#206](https://github.com/teamshares/axn/pull/206) / PRO-2988, shipped in `0.1.0-alpha.5`, which the
  gemspec floor is raised to accordingly. The new name is axn-mcp's, reused verbatim so one concept has
  one name across the adapter family: it names *what it rejects* (rather than a vague `strict:`, which
  would wrongly imply the non-rejected output might not be JSON) and qualifies it with `exposed` so it
  is unambiguously about outbound `exposes` serialization, not inbound `coerce:`. Also `overridable:`,
  again matching axn-mcp — a single tool can opt out via
  `configure(:openapi) { |c| c.reject_opaque_exposed_values = false }` without loosening the whole API,
  and the per-class value wins over the gem-wide one. This gem no longer walks the value graph itself —
  `Serializer` is now a one-line pass-through, and
  `Axn::OpenAPI::UnserializableExposureError` is **removed** in favor of core's
  `Axn::Reflection::UnserializableValue` (an `ArgumentError`, which also names the offending field path).
  Rescue that instead if you referenced the old class. Behavior changes worth noting:
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
  registry (`Axn.register_tool_adapter(:openapi, self)`), so `Axn.tools_for(:openapi)` enumerates
  directory-root and explicitly-declared (`tool :openapi`) tools.
- `[FEAT]` `Axn::OpenAPI::Dispatcher.call(axn_class:, params:, ambient_context: {})` is the spine all
  skins delegate to: it runs the Axn through core's `Axn::Tools::Invoker` and maps the returned
  `Axn::Result` to an `Axn::OpenAPI::Dispatch` (`Data.define(:status, :body)`) per the approved
  status scheme — 200 on success (serialized via `Serializer`), 400 with `field_errors` on caller
  input-contract violations (`Invoker.input_invalid?`), 422 with the `fail!` message on a business
  failure, and a generic no-leak 500 on any other exception or on an `Axn::Reflection::UnserializableValue`
  from serialization (logged via `Axn.config.logger.error`). `params` top-level keys are
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
- `[FEAT]` Module-level facade: `Axn::OpenAPI.tools` (`Axn.tools_for(:openapi, all_versions: true)`), `Axn::OpenAPI.app(
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
  `"#{tool_name}_v#{tool_version}"`. `Axn::OpenAPI.tools` now returns `Axn.tools_for(:openapi,
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
  (all versions of every registered tool) instead of `Axn.tools_for(:openapi)` (latest version
  only). The old default meant `mount Axn::OpenAPI::App.new => "/api"` silently served only the
  newest version of any multi-version tool — the exact drift this gem's versioned-URL scheme
  exists to prevent.
