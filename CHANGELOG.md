# Changelog

## Unreleased

- `[BUGFIX]` A successful Axn whose exposed body isn't JSON-encodable now maps to the documented
  generic `500` envelope instead of raising `JSON::GeneratorError` mid-render (which escaped the Rack
  app / host framework after a `200` was already decided). The dispatcher validates JSON-encodability
  on the success path and routes any failure — a non-finite number (`Float::INFINITY`/`NaN`) or a
  `String` with invalid UTF-8 — through the same no-leak 500 path. Works regardless of
  `strict_serialization` (the strict serializer still runs first for a precise field-level message on
  garbage-but-valid-JSON `to_s` projections).
- `[BUGFIX]` The strict serializer now validates Hash **keys**, not just values: `serialize_value`
  stringifies keys via `#to_s`, so a key with only the default `Object#to_s` (which would render as
  garbage like `"#<User:0x…>"`) is now rejected in strict mode, exactly as such a value is.
- `[BUGFIX]` `SpecGenerator` now derives each operation's `requestBody.required` from the input
  contract (true only when the Axn has a required inbound field) instead of hardcoding `true`. An
  ambient-context-only tool (empty input schema) or an all-optional-input tool is now `required:
  false`, matching the router (which accepts a blank body as `{}`) — so OpenAPI validators and
  generated clients no longer reject a request that succeeds at runtime.
- `[FEAT]` `Axn::OpenAPI` (renamed from the scaffolded `Axn::Openapi`) is now `Axn::Configurable` +
  `Axn::Tools::AdapterRoots`, with settings `path_prefix` (`""`), `spec_path` (`"/openapi.json"`),
  `reject_undeclared_inputs` (`false`), `strict_serialization` (`true`), `info_title` (`"Axn API"`),
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
  failure, and a generic no-leak 500 on any other exception or on an `UnserializableExposureError`
  from strict serialization (logged via `Axn.config.logger.error`). `params` top-level keys are
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
