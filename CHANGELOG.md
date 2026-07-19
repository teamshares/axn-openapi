# Changelog

## Unreleased

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
  `spec_provider.call` (default `-> { {} }`; the real `SpecGenerator` wiring lands in a later task)
  at `spec_path` on GET, looks tools up by `tool_name(:openapi)`, and owns the pre-dispatch
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
