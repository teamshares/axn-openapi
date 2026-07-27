# axn-openapi Version Path Routing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve every tool version at its own explicit path (`POST {prefix}/{tool}/v{n}`) — no bare/default/latest path — so a URL means one version forever and the served routes and the OpenAPI doc are generated from one shared route table.

**Architecture:** Introduce one builder, `Axn::OpenAPI::RouteTable`, that turns the all-versions tool list into an ordered list of `RouteEntry(path, axn, operation_id)`. `Router` builds its dispatch map from it; `SpecGenerator` emits one OpenAPI path per entry. Both call the same builder with the same inputs, so routes and doc can't drift. Dispatcher, Response, Serializer, status/envelope semantics are unchanged.

**Tech Stack:** Ruby ≥ 3.2.1, `axn` (must include PRO-2955/#197 — `tool_version`, `tools_for(all_versions:)`), `rack`, RSpec, RuboCop. Design spec: `internal-docs/specs/2026-07-27-axn-openapi-versioning-design.md`.

## Global Constraints

- **URL scheme (suffix):** `POST {path_prefix}/{tool_name}/v{tool_version}`. A non-versioned tool (`tool_version` == 1) is served at `/{tool_name}/v1`. **No bare `/{tool}` path, no default-version path, no `/latest`.**
- **operationId** = `"{tool_name}_v{tool_version}"`, uniform on every path. Doc-local only — the **version is NEVER encoded into `tool_name`** (locked cross-adapter principle).
- **Enumerate all versions:** `Axn.tools_for(:openapi, all_versions: true)`.
- **Do NOT consume core's `.default`/`versions_for`/`default:` flag** in routing or spec generation.
- **One shared builder:** `RouteTable.build(tools:, path_prefix:)` is the single source of the `{path → axn, operation_id}` map; `Router` and `SpecGenerator` both consume it, neither re-derives paths independently.
- **404 latest-pointer:** a `POST /{tool}/v{n}` whose `tool_name` exists at other versions but not `v{n}` → 404 whose message names the latest available version's path; an entirely unknown `tool_name` → plain 404. This pointer is error-body-only — never a route, never in the spec.
- **Works outside Rails** — guard `Rails`/`ActiveRecord`/`ActiveJob` with `defined?(...)`; core files under `lib/` reference no Rails constants at load time.
- **No parallel path** — reuse core (`tool_name(:openapi)`, `tool_version`, `input_schema`, `output_schema`) and the existing `Dispatcher`/`Response`. TDD; `bundle exec rake verify` pristine (no warnings, no offenses) before a task is done.
- **CHANGELOG.md** `## [Unreleased]` entry per user-visible change.

---

## File Structure

- `lib/axn/openapi/route_table.rb` (**new**) — `RouteEntry` value + `RouteTable.build`.
- `lib/axn/openapi.rb` (**modify**) — `self.tools` → `all_versions: true`; require the new file.
- `lib/axn/openapi/router.rb` (**modify**) — dispatch map from `RouteTable`; versioned matching; 404-latest-pointer.
- `lib/axn/openapi/spec_generator.rb` (**modify**) — paths + operationId from `RouteTable`.
- `spec/support/versioned_tools.rb` (**new**) — non-registered multi-version fixtures for unit specs.
- `spec/axn/openapi/route_table_spec.rb` (**new**); `router_spec.rb`, `spec_generator_spec.rb`, `app_spec.rb`, `facade_spec.rb` (**modify** — bare → versioned paths).
- `spec_rails/dummy_app/app/agent_tools/*`, `config/routes.rb`, `spec/openapi_integration_spec.rb` (**modify** — versioned; add a registered multi-version tool).
- `README.md`, `AGENTS-consuming.md` (**modify** — versioned URL scheme).

---

## Shared unit fixtures (created in Task 1, used by Tasks 1–3)

`spec/support/versioned_tools.rb`. **Critical:** these do NOT declare `tool :openapi` — so they never join the process-global `:openapi` registry (which would pollute `Axn.tools_for(:openapi)` for every other spec). They're passed explicitly via `tools:` to `RouteTable`/`Router`/`SpecGenerator`. `tool_name(:openapi)` and `tool_version` work regardless of adapter membership.

```ruby
# spec/support/versioned_tools.rb
# frozen_string_literal: true

# Two coexisting versions of one logical tool "calc", NOT registered with the :openapi adapter
# (no `tool :openapi`) so they don't leak into the global registry — unit specs pass them explicitly.
class CalcV1Tool
  include Axn
  tool_name :calc
  tool_version 1
  description "Returns the input."
  expects :n, type: Integer
  exposes :result, type: Integer
  def call = expose(result: n)
end

class CalcV2Tool
  include Axn
  tool_name :calc
  tool_version 2
  expects :n, type: Integer
  exposes :doubled, type: Integer
  def call = expose(doubled: n * 2)
end
```

> If `tool_name :calc` + `tool_version` raises a naming assertion (it should not — `CalcV1Tool`'s final constant segment isn't the `Vn` convention), STOP and report NEEDS_CONTEXT rather than working around it.

---

### Task 1: RouteTable builder + all-versions enumeration

**Files:**
- Create: `lib/axn/openapi/route_table.rb`, `spec/support/versioned_tools.rb`, `spec/axn/openapi/route_table_spec.rb`
- Modify: `lib/axn/openapi.rb`

**Interfaces:**
- Produces: `Axn::OpenAPI::RouteEntry = Data.define(:path, :axn, :operation_id)`; `Axn::OpenAPI::RouteTable.build(tools:, path_prefix:) → Array[RouteEntry]`, ordered by `tool_name` then ascending `tool_version`. `path` = `"{path_prefix}/{tool_name}/v{tool_version}"`; `operation_id` = `"{tool_name}_v{tool_version}"`. Also: `Axn::OpenAPI.tools` now returns `Axn.tools_for(:openapi, all_versions: true)`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/route_table_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::RouteTable do
  it "builds one prefixed entry per version, ordered by tool_name then version" do
    entries = described_class.build(tools: [CalcV2Tool, CalcV1Tool], path_prefix: "")
    expect(entries.map(&:path)).to eq(["/calc/v1", "/calc/v2"])
    expect(entries.map(&:operation_id)).to eq(%w[calc_v1 calc_v2])
    expect(entries.map(&:axn)).to eq([CalcV1Tool, CalcV2Tool])
  end

  it "applies the path_prefix" do
    entries = described_class.build(tools: [CalcV1Tool], path_prefix: "/axns")
    expect(entries.first.path).to eq("/axns/calc/v1")
  end

  it "serves an undeclared-version tool at v1" do
    tool = Class.new do
      include Axn
      tool_name :solo
      exposes :ok, type: Symbol
      def call = expose(ok: :yes)
    end
    entries = described_class.build(tools: [tool], path_prefix: "")
    expect(entries.map(&:path)).to eq(["/solo/v1"])
    expect(entries.first.operation_id).to eq("solo_v1")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/route_table_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::RouteTable`.

- [ ] **Step 3: Create the shared fixtures file**

Create `spec/support/versioned_tools.rb` with the content from "Shared unit fixtures" above. (`spec/spec_helper.rb` already loads `spec/support/**/*.rb`.)

- [ ] **Step 4: Write RouteTable**

```ruby
# lib/axn/openapi/route_table.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # One entry per tool version: its served path, the Axn that answers it, and its doc-local
    # operationId. RouteEntry.path already includes the configured path_prefix.
    RouteEntry = Data.define(:path, :axn, :operation_id)

    # The single source of the tool→path map. Router builds its dispatch map from this and
    # SpecGenerator emits its paths from this, so served routes and documented paths can't diverge.
    # Every version is addressable at `{prefix}/{tool_name}/v{tool_version}` — no bare/default/latest.
    module RouteTable
      module_function

      # `tools` is the all-versions enumeration (Axn.tools_for(:openapi, all_versions: true)) or any
      # explicit list. Deterministic order: by tool_name, then ascending tool_version.
      def build(tools:, path_prefix:)
        prefix = path_prefix.to_s
        tools
          .sort_by { |axn| [axn.tool_name(:openapi), axn.tool_version] }
          .map do |axn|
            name = axn.tool_name(:openapi)
            version = axn.tool_version
            RouteEntry.new(
              path: "#{prefix}/#{name}/v#{version}",
              axn:,
              operation_id: "#{name}_v#{version}",
            )
          end
      end
    end
  end
end
```

- [ ] **Step 5: Wire up + switch `self.tools`**

In `lib/axn/openapi.rb`: add `require_relative "openapi/route_table"` at the end (with the other requires), and change `self.tools`:

```ruby
    def self.tools
      Axn.tools_for(:openapi, all_versions: true)
    end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/openapi/route_table_spec.rb` → PASS.
Then `bundle exec rake` → the existing suite still passes (single-version registered tools make `all_versions: true` return the same set the router/spec-generator already handle; the non-registered `Calc*` fixtures never enter `tools_for(:openapi)`).

- [ ] **Step 7: Commit**

```bash
git add lib/axn/openapi/route_table.rb lib/axn/openapi.rb spec/support/versioned_tools.rb spec/axn/openapi/route_table_spec.rb CHANGELOG.md
git commit -m "feat: add RouteTable builder + all-versions enumeration"
```

---

### Task 2: Router version-aware routing

**Files:**
- Modify: `lib/axn/openapi/router.rb`, `spec/axn/openapi/router_spec.rb`, `spec/axn/openapi/app_spec.rb`, `spec/axn/openapi/facade_spec.rb`, `spec_rails/dummy_app/spec/openapi_integration_spec.rb`, `spec_rails/dummy_app/config/routes.rb`

**Interfaces:**
- Consumes: `RouteTable.build`, `Dispatcher.call`.
- Produces: `Router#route` matching `{prefix}/{tool}/v{n}` exact paths; 404 (with latest-version pointer when the tool_name exists at other versions), 405, 400 as before. `Router.new(tools:, path_prefix:, spec_path:, spec_provider:)` signature unchanged.

- [ ] **Step 1: Write the failing test** (rewrite `spec/axn/openapi/router_spec.rb`)

```ruby
# spec/axn/openapi/router_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Router do
  subject(:router) { described_class.new(tools: [EchoTool, CalcV1Tool, CalcV2Tool], spec_provider: -> { { "openapi" => "3.1.0" } }) }

  def route(method, path, body: "", ctx: {})
    router.route(http_method: method, path:, raw_body: body, ambient_context: ctx)
  end

  it "routes POST /<tool>/v1 for a single-version tool" do
    d = route("POST", "/echo_tool/v1", body: '{"message":"hi"}')
    expect(d.status).to eq(200)
    expect(d.body).to eq("echoed" => "hi")
  end

  it "routes each version to its own Axn" do
    expect(route("POST", "/calc/v1", body: '{"n":5}').body).to eq("result" => 5)
    expect(route("POST", "/calc/v2", body: '{"n":5}').body).to eq("doubled" => 10)
  end

  it "has no bare path" do
    expect(route("POST", "/echo_tool", body: '{"message":"hi"}').status).to eq(404)
  end

  it "404s an unknown version of a known tool with a pointer to the latest" do
    d = route("POST", "/calc/v3", body: '{"n":1}')
    expect(d.status).to eq(404)
    expect(d.body["error"]["message"]).to include("/calc/v2")
  end

  it "404s an unknown tool with no pointer" do
    d = route("POST", "/nope/v1", body: "{}")
    expect(d.status).to eq(404)
    expect(d.body["error"]["message"]).not_to include("/v")
  end

  it "serves the spec at GET /openapi.json" do
    expect(route("GET", "/openapi.json").body).to eq("openapi" => "3.1.0")
  end

  it "405s a wrong verb on a known versioned path" do
    expect(route("GET", "/echo_tool/v1").status).to eq(405)
  end

  it "405s a wrong verb on the spec path" do
    expect(route("POST", "/openapi.json", body: "{}").status).to eq(405)
  end

  it "400s a malformed JSON body" do
    expect(route("POST", "/echo_tool/v1", body: "{not json").status).to eq(400)
  end

  it "honors a path_prefix" do
    r = described_class.new(tools: [EchoTool], path_prefix: "/axns")
    expect(r.route(http_method: "POST", path: "/axns/echo_tool/v1", raw_body: '{"message":"hi"}').status).to eq(200)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/router_spec.rb`
Expected: FAIL — current Router keys on bare `tool_name`, so `/echo_tool/v1` 404s and `/echo_tool` "succeeds".

- [ ] **Step 3: Rewrite the Router**

```ruby
# lib/axn/openapi/router.rb
# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # Maps (method, path) to a Dispatch for the mount skin. Every tool version has an exact path
    # ({prefix}/{tool}/v{n}) from the shared RouteTable; there is no bare/default/latest path. Owns
    # the pre-dispatch HTTP-layer cases (404 incl. a latest-version pointer / 405 / 400-parse).
    class Router
      PARSE_ERROR = Object.new.freeze
      private_constant :PARSE_ERROR

      # A path shaped like a tool call, so an unmatched request can be told apart from noise and its
      # tool_name recovered for the 404 latest-version pointer.
      TOOL_PATH = %r{\A/(?<name>[a-z0-9_]+)/v\d+\z}

      def initialize(tools:, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @spec_full = "#{@path_prefix}#{spec_path || Axn::OpenAPI.config.spec_path}"
        @spec_provider = spec_provider || -> { {} }

        entries = RouteTable.build(tools:, path_prefix: @path_prefix)
        @by_path = entries.to_h { |e| [e.path, e.axn] }
        # tool_name => newest entry, for the 404 pointer. Entries are asc by version, so `last` wins.
        @latest_by_name = entries.each_with_object({}) { |e, h| h[e.axn.tool_name(:openapi)] = e }
      end

      def route(http_method:, path:, raw_body:, ambient_context: {})
        return spec_dispatch(http_method) if path == @spec_full

        axn = @by_path[path]
        return not_found(path) unless axn
        return error(405, "Method not allowed") unless http_method == "POST"

        params = parse_json(raw_body)
        return error(400, "Malformed JSON request body") if params.equal?(PARSE_ERROR)

        Dispatcher.call(axn_class: axn, params:, ambient_context:)
      end

      private

      def spec_dispatch(http_method)
        return error(405, "Method not allowed") unless http_method == "GET"

        Dispatch.new(200, @spec_provider.call)
      end

      # A known tool_name at a non-existent version points at the latest available version;
      # anything else is a plain unknown-tool 404. Pointer is error-body only, never a route.
      def not_found(path)
        rel = @path_prefix.empty? ? path : path.delete_prefix(@path_prefix)
        match = TOOL_PATH.match(rel)
        latest = match && @latest_by_name[match[:name]]
        return error(404, "Unknown tool for path #{path}") unless latest

        error(404, "Unknown version for tool '#{match[:name]}'. Latest available: #{latest.path}.")
      end

      def parse_json(raw_body)
        return {} if raw_body.nil? || raw_body.strip.empty?

        parsed = JSON.parse(raw_body)
        parsed.is_a?(Hash) ? parsed : PARSE_ERROR
      rescue JSON::ParserError
        PARSE_ERROR
      end

      def error(status, message) = Dispatch.new(status, { "error" => { "message" => message } })
    end
  end
end
```

- [ ] **Step 4: Update the other Router-driven specs to versioned paths**

These drive requests through the Router (via `App`) and currently assert bare paths. Update the **tool** request paths only (leave the spec-endpoint assertions alone — SpecGenerator is still bare until Task 3, so `paths` still reads `/echo_tool` and those assertions still pass):

- `spec/axn/openapi/app_spec.rb`: change `mock.post("/echo_tool", ...)` → `mock.post("/echo_tool/v1", ...)`; change the context-echo `post("/context_echo_tool", ...)` → `post("/context_echo_tool/v1", ...)`; and the `path_prefix` forwarding test's request `get("/axns/openapi.json")` is unchanged. Leave the "serves the spec" body assertion (`have_key("/echo_tool")`) as-is for now.
- `spec/axn/openapi/facade_spec.rb`: change the `.app` request `post("/echo_tool", ...)` → `post("/echo_tool/v1", ...)`. Leave the `.spec` `have_key("/echo_tool")` assertion for now.
- `spec_rails/dummy_app/config/routes.rb` + `spec_rails/dummy_app/spec/openapi_integration_spec.rb`: change the mounted-tool request `post "/api/echo_tool"` → `post "/api/echo_tool/v1"`, and the `whoami`/context request path `post "/loans/whoami"` is a controller route (NOT through the mount Router) — leave it. Leave the `/api/openapi.json` `have_key("/echo_tool")` assertion for now.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/openapi/router_spec.rb spec/axn/openapi/app_spec.rb spec/axn/openapi/facade_spec.rb` → PASS.
Run: `bundle exec rake verify` → both suites + rubocop pristine. (Intermediate state is intentional: routes are versioned, the doc is still bare — Task 3 makes the doc match.)

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi/router.rb spec/ spec_rails/ CHANGELOG.md
git commit -m "feat: route each tool version at /{tool}/v{n}; 404 points at latest version"
```

---

### Task 3: SpecGenerator version-aware paths

**Files:**
- Modify: `lib/axn/openapi/spec_generator.rb`, `spec/axn/openapi/spec_generator_spec.rb`, `spec/axn/openapi/app_spec.rb`, `spec/axn/openapi/facade_spec.rb`, `spec_rails/dummy_app/spec/openapi_integration_spec.rb`

**Interfaces:**
- Consumes: `RouteTable.build`.
- Produces: `SpecGenerator#generate` emitting one path per `RouteEntry` (keyed by `entry.path`), each `operationId` = `entry.operation_id` (`{tool}_v{n}`), each path's schemas from its own version class.

- [ ] **Step 1: Write the failing test** (update `spec/axn/openapi/spec_generator_spec.rb`)

```ruby
# spec/axn/openapi/spec_generator_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::SpecGenerator do
  subject(:doc) { described_class.new(tools: [EchoTool, CalcV1Tool, CalcV2Tool]).generate }

  it "emits an OpenAPI 3.1 document with an info block" do
    expect(doc["openapi"]).to eq("3.1.0")
    expect(doc["info"]).to include("title" => "Axn API", "version" => "1.0.0")
  end

  it "emits one versioned POST path per tool version" do
    expect(doc["paths"].keys).to include("/echo_tool/v1", "/calc/v1", "/calc/v2")
    expect(doc["paths"]).not_to have_key("/echo_tool") # no bare path
  end

  it "gives each version a doc-unique operationId and its own schemas" do
    v1 = doc.dig("paths", "/calc/v1", "post")
    v2 = doc.dig("paths", "/calc/v2", "post")
    expect(v1["operationId"]).to eq("calc_v1")
    expect(v2["operationId"]).to eq("calc_v2")
    expect(v1.dig("responses", "200", "content", "application/json", "schema")).to eq(CalcV1Tool.output_schema)
    expect(v2.dig("responses", "200", "content", "application/json", "schema")).to eq(CalcV2Tool.output_schema)
  end

  it "still references the shared Error component for failure responses" do
    op = doc.dig("paths", "/echo_tool/v1", "post")
    %w[400 422 500].each do |code|
      expect(op.dig("responses", code, "content", "application/json", "schema")).to eq("$ref" => "#/components/schemas/Error")
    end
  end

  it "honors a path_prefix" do
    d = described_class.new(tools: [EchoTool], path_prefix: "/axns").generate
    expect(d["paths"]).to have_key("/axns/echo_tool/v1")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/spec_generator_spec.rb`
Expected: FAIL — current generator emits bare `/echo_tool` / `/calc` (and collides the two `calc` versions under one key), operationId `calc`.

- [ ] **Step 3: Rewrite `generate` + `path_item` to consume RouteTable**

In `lib/axn/openapi/spec_generator.rb`, replace `generate` and `path_item`:

```ruby
      def generate
        {
          "openapi" => "3.1.0",
          "info" => @info,
          "paths" => RouteTable.build(tools: @tools, path_prefix: @path_prefix)
            .to_h { |entry| [entry.path, path_item(entry)] },
          "components" => { "schemas" => { "Error" => ERROR_SCHEMA } },
        }
      end

      private

      # ...default_info unchanged...

      def path_item(entry)
        axn = entry.axn
        op = {
          "operationId" => entry.operation_id,
          "requestBody" => { "required" => true, "content" => { "application/json" => { "schema" => axn.input_schema } } },
          "responses" => {
            "200" => { "description" => "Success", "content" => { "application/json" => { "schema" => axn.output_schema } } },
            "400" => error_response("Invalid request"),
            "422" => error_response("Operation could not be completed"),
            "500" => error_response("Internal server error"),
          },
        }
        op["summary"] = axn.description if axn.description
        hints = axn._semantic_hints.map(&:to_s)
        op["x-axn-semantic-hints"] = hints unless hints.empty?
        { "post" => op }
      end
```

(`ERROR_SCHEMA`, `ERROR_REF`, `default_info`, `error_response`, and the constructor are unchanged. The constructor no longer needs to build paths itself — it still stores `@tools`/`@path_prefix`/`@info` and passes `@tools`/`@path_prefix` to `RouteTable.build`.)

- [ ] **Step 4: Update the remaining bare-path doc assertions**

Now that the doc is versioned, finish the assertions left bare in Task 2:
- `spec/axn/openapi/app_spec.rb` "serves the spec": `have_key("/echo_tool")` → `have_key("/echo_tool/v1")`.
- `spec/axn/openapi/facade_spec.rb` `.spec`: `have_key("/echo_tool")` → `have_key("/echo_tool/v1")`.
- `spec_rails/dummy_app/spec/openapi_integration_spec.rb` spec assertion: `have_key("/echo_tool")` → `have_key("/echo_tool/v1")`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/openapi/spec_generator_spec.rb spec/axn/openapi/app_spec.rb spec/axn/openapi/facade_spec.rb` → PASS.
Run: `bundle exec rake verify` → pristine. Routes and doc now agree (both from `RouteTable`).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi/spec_generator.rb spec/ spec_rails/ CHANGELOG.md
git commit -m "feat: generate one versioned OpenAPI path per tool version from RouteTable"
```

---

### Task 4: Multi-version Rails integration + docs

**Files:**
- Create: `spec_rails/dummy_app/app/agent_tools/greeter_v1.rb`, `greeter_v2.rb`
- Modify: `spec_rails/dummy_app/config/routes.rb`, `spec_rails/dummy_app/spec/openapi_integration_spec.rb`, `README.md`, `AGENTS-consuming.md`

**Interfaces:**
- Consumes the whole stack end-to-end in a real Rails mount. Proves two coexisting versions of a *registered* tool serve distinct contracts at distinct paths and both appear in the served doc.

- [ ] **Step 1: Write the failing integration test** (add to `spec_rails/dummy_app/spec/openapi_integration_spec.rb`)

```ruby
  it "serves two coexisting versions of a tool at distinct paths with distinct contracts" do
    post "/api/greeter/v1", '{"name":"ada"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("greeting" => "hi ada")

    post "/api/greeter/v2", '{"name":"ada"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("greeting" => "Hello, ada!")
  end

  it "lists both versions in the served spec" do
    get "/api/openapi.json"
    expect(JSON.parse(last_response.body)["paths"].keys).to include("/greeter/v1", "/greeter/v2")
  end

  it "404s a nonexistent version with a pointer to the latest" do
    post "/api/greeter/v9", "{}", "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body)["error"]["message"]).to include("/greeter/v2")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/openapi_integration_spec.rb`
Expected: FAIL — no `greeter` tool / no `/api/greeter/*` routes.

- [ ] **Step 3: Add the registered multi-version tool + mount it**

`spec_rails/dummy_app/app/agent_tools/greeter_v1.rb`:
```ruby
# frozen_string_literal: true
class GreeterV1
  include Axn
  tool :openapi
  tool_name :greeter
  tool_version 1
  expects :name, type: String
  exposes :greeting, type: String
  def call = expose(greeting: "hi #{name}")
end
```

`spec_rails/dummy_app/app/agent_tools/greeter_v2.rb`:
```ruby
# frozen_string_literal: true
class GreeterV2
  include Axn
  tool :openapi
  tool_name :greeter
  tool_version 2
  expects :name, type: String
  exposes :greeting, type: String
  def call = expose(greeting: "Hello, #{name}!")
end
```

Update `spec_rails/dummy_app/config/routes.rb` so the mount serves the greeter versions (keep the existing echo mount + loans routes):
```ruby
  mount Axn::OpenAPI.app(tools: [EchoTool, GreeterV1, GreeterV2]) => "/api"
```

- [ ] **Step 4: Run to verify integration passes**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/openapi_integration_spec.rb`
Expected: PASS.

- [ ] **Step 5: Update the docs**

- `README.md`: replace the routing/URL section — endpoints are `POST {mount}{path_prefix}/{tool}/v{n}`; a non-versioned tool is at `/v1`; there is **no** bare/default/latest path; "newest version" is read from the spec (highest `vN`), not a magic route; a 404 on an unknown version of a known tool points at the latest. Update any example paths (`/approve_loan` → `/approve_loan/v1`).
- `AGENTS-consuming.md`: same URL-scheme correction, and note that declaring `tool_version N` on a second Axn sharing a `tool_name` adds a `/vN` path without touching existing versions' paths.

- [ ] **Step 6: Full gate + commit**

Run: `bundle exec rake verify` → pristine.

```bash
git add spec_rails/ README.md AGENTS-consuming.md CHANGELOG.md
git commit -m "test: multi-version Rails integration; docs for versioned URL scheme"
```

---

## Self-Review

**1. Spec coverage** (design doc → task):
- Suffix `/{tool}/v{n}`, non-versioned ⇒ `/v1` → Tasks 1 (RouteTable) + 2 (Router) + 3 (SpecGenerator). ✅
- No bare/default/latest; ignore `.default` → RouteTable emits only versioned paths; Router has no bare branch; explicit "no bare path" test (Task 2) + "not bare" doc test (Task 3). ✅
- All-versions enumeration → Task 1 (`self.tools`). ✅
- operationId `{tool}_v{n}`, version never in tool_name → RouteTable `operation_id`; asserted Task 3. ✅
- Per-version schemas → each path's schema from its own class; asserted Task 3 (`CalcV1/2` output_schema) + Task 4 (distinct contracts). ✅
- Shared RouteTable so router+spec agree → Task 1 builder consumed by Tasks 2 & 3. ✅
- 404 latest-version pointer (known tool, unknown version) vs plain 404 (unknown tool) → Task 2 (`not_found`) + tests Tasks 2 & 4. ✅
- Spec endpoint unchanged → Router `@spec_full`; asserted Tasks 2/3. ✅
- Update existing bare-path tests + docs → Tasks 2/3 (specs), Task 4 (Rails + docs). ✅

**2. Placeholder scan:** No TBD/TODO; complete code for the new file and both rewrites; test updates specify exact old→new path strings. ✅

**3. Type consistency:** `RouteEntry(path, axn, operation_id)` consumed identically in Router (`entry.axn`) and SpecGenerator (`entry.path`/`entry.operation_id`). `RouteTable.build(tools:, path_prefix:)` signature identical at both call sites and in Task 1's tests. `tool_version` (zero-arg reader) and `tool_name(:openapi)` used consistently. Router `@spec_full` replaces the old `strip_prefix`/`@spec_path` matching. ✅

**Fixes applied inline:** unit fixtures deliberately omit `tool :openapi` to avoid polluting the process-global registry (they're passed explicitly); the registered multi-version tool lives only in the dummy app (separate bundle/process). Task ordering keeps every task green — Task 2 leaves the doc bare (spec-endpoint assertions untouched) and Task 3 flips them, an intentional two-step for the cross-cutting URL change.
