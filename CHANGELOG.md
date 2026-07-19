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
