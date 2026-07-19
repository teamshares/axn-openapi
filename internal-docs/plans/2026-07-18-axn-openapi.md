# axn-openapi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve Axns over HTTP as an OpenAPI 3.1-described JSON API — auto-generate the spec, route inbound requests to the right Axn, run it, return JSON.

**Architecture:** One transport-agnostic core (`Dispatcher`) that runs a tool through `Axn::Tools::Invoker` and maps the `Axn::Result` to `{status, body}`, with three thin skins over it: a mountable Rack app (`App` + `Router`), a controller mixin (`Controller#render_axn`), and a spec generator (`SpecGenerator`). All read the same axn-core reflection surface (`input_schema`/`output_schema`/`tool_name`/`_semantic_hints`) and add no parallel path.

**Tech Stack:** Ruby ≥ 3.2.1, `axn` (core), `rack` (request/response), RSpec, RuboCop. Spec design: `internal-docs/specs/2026-07-18-axn-openapi-design.md`.

## Global Constraints

- **Ruby ≥ 3.2.1**; depend only on `axn` (`>= 0.1.0-alpha.4.3, < 0.2.0`) + `rack` at runtime.
- **Works outside Rails** — guard every `Rails`/`ActiveRecord`/`ActiveJob` reference with `defined?(...)`. Core (`Dispatcher`, `Router`, `App`, `SpecGenerator`, `Serializer`, `Response`, `Request`) must never require Rails.
- **Module namespace is `Axn::OpenAPI`** (acronym casing, like `Axn::MCP`) — normalize the scaffolded `Axn::Openapi` in Task 1. Files stay under `lib/axn/openapi/`.
- **No parallel path** — reuse `Axn::Tools::Invoker`, `Axn::Reflection::Values.serialize_exposed`, `axn_class.input_schema`/`output_schema`/`external_field_configs`/`tool_name(:openapi)`/`_semantic_hints`/`description`. Never reimplement schema or serialization.
- **TDD**: failing test first, minimal impl, frequent commits. `bundle exec rake` (specs + rubocop) must pass before a task is done.
- **CHANGELOG.md** entry under `## [Unreleased]` per user-visible change. **AGENTS-consuming.md** is the shipped agent-facing usage guide (allowlisted in the gemspec).
- **Response contract (decided in the spec, do not re-litigate):**
  - Success (2xx): **bare** `output_schema` body (exposed keys at top level, no wrapper).
  - Failure (4xx/5xx): envelope `{"error": {"message": ..., ["field_errors": [...]]}}`.
  - Status map (Scheme 1): `200` ok · `400` malformed JSON **and** `InboundValidationError` · `404` unknown tool · `405` wrong verb · `422` business `fail!` · `500` unexpected/unserializable.
  - Run the Invoker with `user_facing_input_errors: true`; detect caller-input errors with `Axn::Tools::Invoker.input_invalid?(result)` (NOT `outcome` alone — that would let `user_facing:` move the line).

---

## File Structure

All paths relative to the gem root `/Users/kali/code/core/axn-openapi`.

- `lib/axn/openapi/version.rb` — `Axn::OpenAPI::VERSION` (rename module).
- `lib/axn/openapi.rb` — module: `Axn::Configurable` settings, `Axn::Tools::AdapterRoots`, `register_tool_adapter(:openapi)`, error classes, `.deprecator`, and (Task 9) the `.app`/`.spec`/`.tools` entry points. Requires the files below.
- `lib/axn-openapi.rb` — top-level require shim (scaffolded; leave as-is).
- `lib/axn/openapi/dispatch.rb` — `Dispatch = Data.define(:status, :body)` value object.
- `lib/axn/openapi/errors.rb` — `Error`, `UnserializableExposureError`.
- `lib/axn/openapi/serializer.rb` — strict-guarded delegation to `serialize_exposed`.
- `lib/axn/openapi/dispatcher.rb` — the spine: Invoker + status mapping + envelopes.
- `lib/axn/openapi/response.rb` — Rack response value object (`status`/`body`/`headers`/`to_rack`).
- `lib/axn/openapi/request.rb` — Rails-agnostic request view (`raw_body`/`http_method`/`path`).
- `lib/axn/openapi/router.rb` — `(method, path) → Dispatch` (tool lookup, spec route, 404/405/400-parse).
- `lib/axn/openapi/app.rb` — mountable Rack app (`call(env)`).
- `lib/axn/openapi/controller.rb` — controller mixin (`render_axn`).
- `lib/axn/openapi/spec_generator.rb` — assemble the OpenAPI document from reflection.
- `spec/**` — unit specs per file. `spec_rails/dummy_app` — Rails mount + controller integration.
- `spec/support/tools.rb` — shared example Axns used across specs (defined once, DRY).

---

## Shared test fixtures (referenced by many tasks)

Create `spec/support/tools.rb` in Task 1 and require it from `spec/spec_helper.rb`. Every later task's tests use these:

```ruby
# spec/support/tools.rb
# frozen_string_literal: true

# A happy-path tool with a nested-object output and a semantic hint.
class EchoTool
  include Axn
  tool :openapi
  semantic_hints :read_only
  description "Echoes a message back."
  expects :message, type: String
  exposes :echoed, type: String
  def call = expose(echoed: message)
end

# A tool that fails a business rule via fail!.
class RefuseTool
  include Axn
  tool :openapi
  description "Always refuses."
  expects :amount, type: Integer
  def call = fail!("Amount too large")
end

# A tool whose call raises an unexpected exception.
class BoomTool
  include Axn
  tool :openapi
  expects :x, type: Integer
  def call = raise "kaboom"
end

# A tool that exposes an object with only the default Object#to_s (unserializable).
class OpaqueValue; end
class OpaqueTool
  include Axn
  tool :openapi
  exposes :thing
  def call = expose(thing: OpaqueValue.new)
end
```

> NOTE: `tool :openapi` gives an explicit membership grant so these fixtures don't depend on directory-root discovery. Directory-root membership (`agent_tools/`) is covered separately in Task 1.

---

### Task 1: Module normalization, config, adapter registration

**Files:**
- Modify: `lib/axn/openapi/version.rb`
- Modify: `lib/axn/openapi.rb`
- Test: `spec/axn/openapi_spec.rb`, `spec/axn/openapi/registration_spec.rb`
- Create: `spec/support/tools.rb`; Modify: `spec/spec_helper.rb`

**Interfaces:**
- Produces: `Axn::OpenAPI` module extending `Axn::Configurable` + `Axn::Tools::AdapterRoots`; settings `path_prefix` (`""`), `spec_path` (`"/openapi.json"`), `reject_undeclared_inputs` (`false`), `strict_serialization` (`true`), `info_title` (`"Axn API"`), `info_version` (`"1.0.0"`), `info_description` (`nil`), `tool_roots` (`%w[agent_tools]`). Registered with core via `Axn.register_tool_adapter(:openapi, self)`, so `Axn.tools_for(:openapi)` works.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI do
  it "exposes the acronym-cased namespace and version" do
    expect(Axn::OpenAPI::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  it "defaults its config" do
    expect(Axn::OpenAPI.config.path_prefix).to eq("")
    expect(Axn::OpenAPI.config.spec_path).to eq("/openapi.json")
    expect(Axn::OpenAPI.config.reject_undeclared_inputs).to be(false)
    expect(Axn::OpenAPI.config.strict_serialization).to be(true)
    expect(Axn::OpenAPI.config.info_title).to eq("Axn API")
    expect(Axn::OpenAPI.config.info_version).to eq("1.0.0")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI` (scaffold defines `Axn::Openapi`).

- [ ] **Step 3: Rename the version module**

```ruby
# lib/axn/openapi/version.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    VERSION = "0.1.0"
  end
end
```

- [ ] **Step 4: Rewrite the main module**

```ruby
# lib/axn/openapi.rb
# frozen_string_literal: true

require "axn"
require "active_support/deprecation"

require_relative "openapi/version"

module Axn
  module OpenAPI
    extend Axn::Configurable
    extend Axn::Tools::AdapterRoots

    config_namespace :openapi

    # Route surface.
    setting :path_prefix, default: ""
    setting :spec_path, default: "/openapi.json"

    # Dispatch behavior.
    setting :reject_undeclared_inputs, default: false
    setting :strict_serialization, default: true

    # OpenAPI `info` object (title + version are required by the spec format).
    setting :info_title, default: "Axn API"
    setting :info_version, default: "1.0.0"
    setting :info_description, default: nil

    # Directory-root membership: an Axn under app/agent_tools/ is served without an explicit
    # `tool :openapi` — same default root as axn-mcp/axn-ruby_llm, so one tool serves everywhere.
    setting :tool_roots, default: %w[agent_tools], validate: ->(v) { Axn::Tools::AdapterRoots.validate!(v) }

    class Error < StandardError; end

    def self.deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-openapi")
    end

    # Register :openapi with core's process-global registry, passing this module as the config
    # source so the registry reads Axn::OpenAPI.config.tool_roots for directory membership.
    Axn.register_tool_adapter(:openapi, self)
  end
end
```

- [ ] **Step 5: Wire shared fixtures into the spec helper**

Create `spec/support/tools.rb` with the content from "Shared test fixtures" above, and add to `spec/spec_helper.rb` (after `require`ing the gem):

```ruby
Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }
```

- [ ] **Step 6: Write the registration test**

```ruby
# spec/axn/openapi/registration_spec.rb
# frozen_string_literal: true

RSpec.describe "openapi adapter registration" do
  it "registers the :openapi adapter with core" do
    expect(Axn::Tools::Registry.adapters).to include(:openapi)
  end

  it "enumerates explicitly-declared :openapi tools" do
    expect(Axn.tools_for(:openapi)).to include(EchoTool, RefuseTool)
  end
end
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/openapi_spec.rb spec/axn/openapi/registration_spec.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/openapi.rb lib/axn/openapi/version.rb spec/
git commit -m "feat: normalize Axn::OpenAPI namespace, config, adapter registration"
```

---

### Task 2: Response value object

**Files:**
- Create: `lib/axn/openapi/response.rb`
- Test: `spec/axn/openapi/response_spec.rb`

**Interfaces:**
- Produces: `Axn::OpenAPI::Response.new(status:, body:, headers:)`; `.json(hash, status:)` builds a JSON response; `#to_rack → [status, headers, [body]]`; `#==`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/response_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Response do
  it "renders a Rack triple with lower-cased headers" do
    resp = described_class.new(status: 201, body: "hi", headers: { "X-A" => "b" })
    status, headers, body = resp.to_rack
    expect(status).to eq(201)
    expect(headers).to eq("x-a" => "b")
    expect(body).to eq(["hi"])
  end

  it "builds a JSON response with content-type and encoded body" do
    resp = described_class.json({ echoed: "hi" }, status: 200)
    status, headers, body = resp.to_rack
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")
    expect(JSON.parse(body.first)).to eq("echoed" => "hi")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/response_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::Response`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/axn/openapi/response.rb
# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # A Rails-agnostic HTTP response value: status + JSON body + headers. Mirrors
    # axn-webhooks' Response. #to_rack renders the [status, headers, [body]] triple.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status: 200, body: "", headers: {})
        @status = status
        @body = body.to_s
        @headers = headers.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v.to_s }
        freeze
      end

      # Build a JSON response from a Ruby Hash/Array (nil body → empty object body).
      def self.json(data, status: 200, headers: {})
        new(status:, body: JSON.generate(data.nil? ? {} : data),
            headers: { "content-type" => "application/json" }.merge(headers))
      end

      def ==(other)
        other.is_a?(self.class) && status == other.status && body == other.body && headers == other.headers
      end

      def to_rack = [status, headers.dup, [body]]
    end
  end
end
```

- [ ] **Step 4: Require it from the main module**

Add to `lib/axn/openapi.rb` after the module definition (before `Axn.register_tool_adapter`, or at file end — order-free since it only defines a class):

```ruby
require_relative "openapi/response"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/response_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi/response.rb lib/axn/openapi.rb spec/axn/openapi/response_spec.rb
git commit -m "feat: add Rack Response value object"
```

---

### Task 3: Strict serializer

**Files:**
- Create: `lib/axn/openapi/errors.rb`, `lib/axn/openapi/serializer.rb`
- Test: `spec/axn/openapi/serializer_spec.rb`

**Interfaces:**
- Produces: `Axn::OpenAPI::UnserializableExposureError` (with `#field_path`); `Axn::OpenAPI::Serializer.serialize(result, field_configs, strict:) → Hash`. Delegates the actual serialization to `Axn::Reflection::Values.serialize_exposed`; when `strict`, first raises `UnserializableExposureError` if any exposed leaf would fall through to the **default** `Object#/Kernel#to_s`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/serializer_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Serializer do
  def serialize(axn, strict: true)
    result = axn.call
    described_class.serialize(result, axn.external_field_configs, strict:)
  end

  it "serializes scalars via serialize_exposed (schema-aligned)" do
    klass = Class.new do
      include Axn
      exposes :n, type: Integer
      exposes :t, type: Time
      def call = expose(n: 3, t: Time.utc(2020, 1, 2, 3, 4, 5))
    end
    out = serialize(klass)
    expect(out["n"]).to eq(3)
    expect(out["t"]).to eq("2020-01-02T03:04:05Z")
  end

  it "raises on a value with only the default Object#to_s when strict" do
    expect { serialize(OpaqueTool) }.to raise_error(Axn::OpenAPI::UnserializableExposureError, /thing/)
  end

  it "allows a value with a meaningful custom to_s" do
    money = Class.new { def to_s = "$4.00" }
    klass = Class.new do
      include Axn
      exposes :price
      define_method(:call) { expose(price: money.new) }
    end
    expect(serialize(klass)["price"]).to eq("$4.00")
  end

  it "never raises when strict is false (mirrors MCP leniency)" do
    expect { serialize(OpaqueTool, strict: false) }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/serializer_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::Serializer`.

- [ ] **Step 3: Write the error class**

```ruby
# lib/axn/openapi/errors.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # Raised (in strict mode) when an exposed value has no meaningful JSON projection — no own
    # as_json, no to_h, and only the inherited Object/Kernel #to_s. The Dispatcher maps it to 500:
    # shipping "#<User:0x…>" to an API consumer is a contract bug in the same family as an
    # OutboundValidationError. #field_path names the offending exposure for the dev-facing message.
    class UnserializableExposureError < Error
      attr_reader :field_path

      def initialize(field_path, value)
        @field_path = field_path
        super(
          "Exposed value at `#{field_path}` (#{value.class}) has no JSON representation — it serializes " \
          "only via the default Object#to_s. Declare it `type: String` and format it, or give the value " \
          "an `as_json`/`to_h`. (Disable with Axn::OpenAPI.config.strict_serialization = false.)"
        )
      end
    end
  end
end
```

- [ ] **Step 4: Write the serializer**

```ruby
# lib/axn/openapi/serializer.rb
# frozen_string_literal: true

require "date"

module Axn
  module OpenAPI
    # Success-body serialization. The actual work is axn core's canonical, schema-aligned
    # Axn::Reflection::Values.serialize_exposed (the same serializer axn-mcp uses), so the body
    # matches output_schema by construction. In strict mode a pre-pass raises on any exposed leaf
    # that serialize_value would render via the default Object#to_s — a garbage projection an HTTP
    # contract must not ship silently.
    module Serializer
      module_function

      # Leaf types serialize_value handles losslessly (see Axn::Reflection::Values.serialize_value).
      SAFE_LEAVES = [NilClass, String, Integer, Float, TrueClass, FalseClass, Symbol, Numeric,
                     Time, DateTime, Date].freeze
      DEFAULT_TO_S_OWNERS = [::Object, ::Kernel].freeze

      def serialize(result, field_configs, strict:)
        if strict
          field_configs.each { |c| assert_serializable!(result.public_send(c.field), c.field.to_s) }
        end
        Axn::Reflection::Values.serialize_exposed(result, field_configs)
      end

      # Mirrors serialize_value's branch decisions (reusing Values.follow_as_json? so the two can't
      # drift): a value is serializable unless it reaches the `value.to_s` branch (no own as_json,
      # no to_h) AND that to_s is the inherited default.
      def assert_serializable!(value, path)
        return if SAFE_LEAVES.any? { |k| value.is_a?(k) }
        return value.each { |k, v| assert_serializable!(v, "#{path}.#{k}") } if value.is_a?(Hash)
        return value.each_with_index { |v, i| assert_serializable!(v, "#{path}[#{i}]") } if value.is_a?(Array)
        return if Axn::Reflection::Values.follow_as_json?(value) # serialize_value follows as_json
        return if value.respond_to?(:to_h)                       # serialize_value follows to_h
        return unless DEFAULT_TO_S_OWNERS.include?(value.method(:to_s).owner)

        raise UnserializableExposureError.new(path, value)
      end
    end
  end
end
```

- [ ] **Step 5: Require both from the main module**

Add to `lib/axn/openapi.rb`:

```ruby
require_relative "openapi/errors"
require_relative "openapi/serializer"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/serializer_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/openapi/errors.rb lib/axn/openapi/serializer.rb lib/axn/openapi.rb spec/axn/openapi/serializer_spec.rb
git commit -m "feat: add strict-guarded success serializer"
```

---

### Task 4: Dispatcher (the spine)

**Files:**
- Create: `lib/axn/openapi/dispatch.rb`, `lib/axn/openapi/dispatcher.rb`
- Test: `spec/axn/openapi/dispatcher_spec.rb`

**Interfaces:**
- Consumes: `Axn::OpenAPI::Serializer.serialize`, `Axn::OpenAPI.config`.
- Produces: `Axn::OpenAPI::Dispatch = Data.define(:status, :body)` (body is a JSON-ready Hash). `Axn::OpenAPI::Dispatcher.call(axn_class:, params:, ambient_context: {}) → Dispatch`. `params` is a Hash with **any-typed** keys; Dispatcher symbolizes the top level before the Invoker splat.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/dispatcher_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Dispatcher do
  def dispatch(axn, params) = described_class.call(axn_class: axn, params:)

  it "returns 200 with the bare output body on success" do
    d = dispatch(EchoTool, { "message" => "hi" })
    expect(d.status).to eq(200)
    expect(d.body).to eq("echoed" => "hi")
  end

  it "returns 400 with field_errors on invalid input" do
    d = dispatch(EchoTool, {}) # missing required :message
    expect(d.status).to eq(400)
    expect(d.body["error"]["field_errors"].map { |e| e[:field] }).to include(:message)
  end

  it "returns 422 with the fail! message on a business failure" do
    d = dispatch(RefuseTool, { "amount" => 5 })
    expect(d.status).to eq(422)
    expect(d.body["error"]["message"]).to eq("Amount too large")
  end

  it "returns 500 generic on an unexpected exception (no leak)" do
    d = dispatch(BoomTool, { "x" => 1 })
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "returns 500 when a successful result is unserializable (strict)" do
    d = dispatch(OpaqueTool, {})
    expect(d.status).to eq(500)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/dispatcher_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::Dispatcher`.

- [ ] **Step 3: Write the Dispatch value**

```ruby
# lib/axn/openapi/dispatch.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # The transport-agnostic result of running a tool: an HTTP status + a JSON-ready body Hash.
    # Every skin (Rack app, controller mixin) renders this the same way.
    Dispatch = Data.define(:status, :body)
  end
end
```

- [ ] **Step 4: Write the Dispatcher**

```ruby
# lib/axn/openapi/dispatcher.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # The spine. Runs an Axn through the sanctioned Axn::Tools::Invoker and maps the returned
    # Axn::Result to a Dispatch (status + body) per the approved status scheme. This is the ONLY
    # place error/status semantics live; all three skins delegate here.
    module Dispatcher
      module_function

      GENERIC_500 = { "error" => { "message" => "Internal Server Error" } }.freeze

      def call(axn_class:, params:, ambient_context: {})
        invoker = Axn::Tools::Invoker.new(
          user_facing_input_errors: true,
          reject_undeclared_inputs: Axn::OpenAPI.config.reject_undeclared_inputs,
        )
        # Top-level keys must be Symbols for the Invoker's `**` splat; nested Hashes stay as-is
        # (axn reads nested subfields by key from a Hash source regardless of key type).
        result = invoker.call(axn_class, symbolize_top(params), ambient_context:)

        return success(axn_class, result) if result.ok?
        return validation_error(result) if Axn::Tools::Invoker.input_invalid?(result)   # 400
        return failure(result) if result.outcome.failure?                               # 422

        Dispatch.new(500, GENERIC_500)                                                   # already paged on_exception
      end

      def success(axn_class, result)
        body = Serializer.serialize(result, axn_class.external_field_configs,
                                    strict: Axn::OpenAPI.config.strict_serialization)
        Dispatch.new(200, body)
      rescue UnserializableExposureError => e
        Axn.config.logger.error { "[axn-openapi] #{e.message}" }
        Dispatch.new(500, GENERIC_500)
      end

      def validation_error(result)
        error = { "message" => result.error }
        error["field_errors"] = result.exception.field_errors if result.exception.respond_to?(:field_errors)
        Dispatch.new(400, { "error" => error })
      end

      def failure(result)
        Dispatch.new(422, { "error" => { "message" => result.error } })
      end

      def symbolize_top(params)
        params.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end
    end
  end
end
```

- [ ] **Step 5: Require both from the main module**

Add to `lib/axn/openapi.rb`:

```ruby
require_relative "openapi/dispatch"
require_relative "openapi/dispatcher"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/dispatcher_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/openapi/dispatch.rb lib/axn/openapi/dispatcher.rb lib/axn/openapi.rb spec/axn/openapi/dispatcher_spec.rb
git commit -m "feat: add Dispatcher — Invoker run + status/envelope mapping"
```

---

### Task 5: Request view + Router

**Files:**
- Create: `lib/axn/openapi/request.rb`, `lib/axn/openapi/router.rb`
- Test: `spec/axn/openapi/router_spec.rb`

**Interfaces:**
- Consumes: `Axn::OpenAPI::Dispatcher.call`, `Axn::OpenAPI::SpecGenerator` (forward reference; the Router calls `SpecGenerator.new(tools:).generate` — implemented in Task 8, so gate that one branch behind a guard until then... no: implement Task 8 has no dependency the other way, but Router needs it. To keep tasks independently testable, Router takes a `spec_provider:` callable, default `-> { {} }`, and Task 9 wires the real generator). 
- Produces: `Axn::OpenAPI::Request.new(http_method:, path:, raw_body:)`; `Axn::OpenAPI::Router.new(tools:, path_prefix: nil, spec_path: nil, spec_provider: nil)`; `#route(http_method:, path:, raw_body:, ambient_context: {}) → Dispatch`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/router_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Router do
  subject(:router) { described_class.new(tools: [EchoTool, RefuseTool], spec_provider: -> { { "openapi" => "3.1.0" } }) }

  def route(method, path, body: "", ctx: {})
    router.route(http_method: method, path:, raw_body: body, ambient_context: ctx)
  end

  it "routes POST /<tool_name> to the dispatcher" do
    d = route("POST", "/echo_tool", body: '{"message":"hi"}')
    expect(d.status).to eq(200)
    expect(d.body).to eq("echoed" => "hi")
  end

  it "serves the spec at GET /openapi.json" do
    d = route("GET", "/openapi.json")
    expect(d.status).to eq(200)
    expect(d.body).to eq("openapi" => "3.1.0")
  end

  it "404s an unknown tool" do
    expect(route("POST", "/nope", body: "{}").status).to eq(404)
  end

  it "405s a wrong verb on a known tool" do
    expect(route("GET", "/echo_tool").status).to eq(405)
  end

  it "400s a malformed JSON body" do
    d = route("POST", "/echo_tool", body: "{not json")
    expect(d.status).to eq(400)
    expect(d.body["error"]["message"]).to match(/malformed|json/i)
  end

  it "honors a path_prefix" do
    r = described_class.new(tools: [EchoTool], path_prefix: "/axns")
    expect(r.route(http_method: "POST", path: "/axns/echo_tool", raw_body: '{"message":"hi"}').status).to eq(200)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/router_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::Router`.

- [ ] **Step 3: Write the Request view**

```ruby
# lib/axn/openapi/request.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # A Rails-agnostic view of an inbound HTTP request, built from a Rack env or directly in tests.
    Request = Data.define(:http_method, :path, :raw_body) do
      def self.from_rack(env)
        input = env["rack.input"]
        raw_body = input ? input.read.to_s : ""
        begin
          input&.rewind
        rescue StandardError
          nil # rewind is a courtesy; raw_body is already captured
        end
        new(http_method: env["REQUEST_METHOD"].to_s.upcase, path: env["PATH_INFO"].to_s, raw_body:)
      end
    end
  end
end
```

- [ ] **Step 4: Write the Router**

```ruby
# lib/axn/openapi/router.rb
# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # Maps (method, path) to a Dispatch for the mount skin: strips the prefix, serves the spec,
    # looks the tool up by tool_name, and owns the pre-dispatch HTTP-layer cases (404/405/400-parse).
    class Router
      def initialize(tools:, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @spec_path = spec_path || Axn::OpenAPI.config.spec_path
        @spec_provider = spec_provider || -> { {} }
        @by_name = tools.to_h { |axn| [axn.tool_name(:openapi), axn] }
      end

      def route(http_method:, path:, raw_body:, ambient_context: {})
        rel = strip_prefix(path)
        return spec_dispatch(http_method) if rel == @spec_path

        tool = @by_name[rel.delete_prefix("/")]
        return error(404, "Unknown tool: #{rel.delete_prefix('/')}") unless tool
        return error(405, "Method not allowed") unless http_method == "POST"

        params = parse_json(raw_body)
        return error(400, "Malformed JSON request body") if params.equal?(PARSE_ERROR)

        Dispatcher.call(axn_class: tool, params:, ambient_context:)
      end

      private

      PARSE_ERROR = Object.new.freeze

      def spec_dispatch(http_method)
        return error(405, "Method not allowed") unless http_method == "GET"

        Dispatch.new(200, @spec_provider.call)
      end

      def strip_prefix(path)
        return path if @path_prefix.empty?

        path.start_with?(@path_prefix) ? path.delete_prefix(@path_prefix) : path
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

- [ ] **Step 5: Require both from the main module**

Add to `lib/axn/openapi.rb`:

```ruby
require_relative "openapi/request"
require_relative "openapi/router"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/router_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/openapi/request.rb lib/axn/openapi/router.rb lib/axn/openapi.rb spec/axn/openapi/router_spec.rb
git commit -m "feat: add Request view and Router (tool lookup, spec route, 404/405/400)"
```

---

### Task 6: Mountable Rack app

**Files:**
- Create: `lib/axn/openapi/app.rb`
- Test: `spec/axn/openapi/app_spec.rb`

**Interfaces:**
- Consumes: `Router`, `Request`, `Response`, `SpecGenerator` (via `spec_provider`).
- Produces: `Axn::OpenAPI::App.new(tools:, context: nil, path_prefix: nil, spec_path: nil, spec_provider: nil)` responding to `#call(env) → [status, headers, [body]]`. `context:` is a callable `env → Hash` producing the trusted `ambient_context` (default `->(_env) { {} }`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/app_spec.rb
# frozen_string_literal: true

require "rack/mock"

RSpec.describe Axn::OpenAPI::App do
  let(:app) { described_class.new(tools: [EchoTool], spec_provider: -> { { "openapi" => "3.1.0" } }) }
  let(:mock) { Rack::MockRequest.new(app) }

  it "serves a tool over a real Rack request" do
    res = mock.post("/echo_tool", input: '{"message":"hi"}', "CONTENT_TYPE" => "application/json")
    expect(res.status).to eq(200)
    expect(JSON.parse(res.body)).to eq("echoed" => "hi")
    expect(res.headers["content-type"]).to eq("application/json")
  end

  it "serves the spec" do
    res = mock.get("/openapi.json")
    expect(JSON.parse(res.body)).to eq("openapi" => "3.1.0")
  end

  it "passes ambient_context built from env" do
    ctx_app = described_class.new(tools: [ContextEchoTool], context: ->(env) { { actor: env["HTTP_X_ACTOR"] } })
    res = Rack::MockRequest.new(ctx_app).post("/context_echo_tool", input: "{}", "HTTP_X_ACTOR" => "alice")
    expect(JSON.parse(res.body)).to eq("actor" => "alice")
  end
end
```

Add this fixture to `spec/support/tools.rb`:

```ruby
# Reads a value from ambient_context (the auth/request-context seam) and echoes it.
class ContextEchoTool
  include Axn
  tool :openapi
  expects :actor, on: :ambient_context, type: String, allow_nil: true
  exposes :actor, type: String, allow_nil: true
  def call = expose(actor:)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/app_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::App`.

- [ ] **Step 3: Write the app**

```ruby
# lib/axn/openapi/app.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # A framework-agnostic Rack app. Directly `mount`able in a Rails routes file
    # (`mount Axn::OpenAPI::App.new(...) => "/api"`) or `run`-able in a bare Rack::Builder — the
    # mount point is the path prefix. `context:` maps the Rack env to the trusted ambient_context
    # (e.g. current_user), the auth seam the gem offers but does not own.
    class App
      def initialize(tools: nil, context: nil, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @tools = tools || Axn.tools_for(:openapi)
        @context = context || ->(_env) { {} }
        provider = spec_provider || -> { SpecGenerator.new(tools: @tools).generate }
        @router = Router.new(tools: @tools, path_prefix:, spec_path:, spec_provider: provider)
      end

      def call(env)
        request = Request.from_rack(env)
        dispatch = @router.route(
          http_method: request.http_method,
          path: request.path,
          raw_body: request.raw_body,
          ambient_context: @context.call(env),
        )
        Response.json(dispatch.body, status: dispatch.status).to_rack
      end
    end
  end
end
```

- [ ] **Step 4: Require it, and add `rack` as a runtime dependency**

Add to `lib/axn/openapi.rb`: `require_relative "openapi/app"`.
Add to `axn-openapi.gemspec` (after the axn dependency): `spec.add_dependency "rack", ">= 2.2"`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/app_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi/app.rb lib/axn/openapi.rb axn-openapi.gemspec spec/
git commit -m "feat: add mountable Rack App skin"
```

---

### Task 7: Controller mixin

**Files:**
- Create: `lib/axn/openapi/controller.rb`
- Test: `spec/axn/openapi/controller_spec.rb`

**Interfaces:**
- Consumes: `Dispatcher.call`.
- Produces: `Axn::OpenAPI::Controller` — `include` into a Rails controller; `render_axn(axn_class, ambient_context: {})` reads the request body + renders `render json: dispatch.body, status: dispatch.status`. Bypasses `Router` (the controller owns routing/auth), delegating straight to `Dispatcher`.

- [ ] **Step 1: Write the failing test** (a fake controller double — no Rails needed)

```ruby
# spec/axn/openapi/controller_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Controller do
  # Minimal stand-in for an ActionController: exposes #request.raw_post and captures #render.
  let(:controller_class) do
    Class.new do
      include Axn::OpenAPI::Controller
      attr_accessor :rendered
      Req = Struct.new(:raw_post)
      def initialize(body) = @body = body
      def request = Req.new(@body)
      def render(json:, status:) = self.rendered = { json:, status: }
    end
  end

  it "dispatches the given Axn and renders json + status" do
    c = controller_class.new('{"message":"hi"}')
    c.render_axn(EchoTool)
    expect(c.rendered[:status]).to eq(200)
    expect(c.rendered[:json]).to eq("echoed" => "hi")
  end

  it "forwards ambient_context (e.g. current_user)" do
    c = controller_class.new("{}")
    c.render_axn(ContextEchoTool, ambient_context: { actor: "bob" })
    expect(c.rendered[:json]).to eq("actor" => "bob")
  end

  it "maps a business failure to 422" do
    c = controller_class.new('{"amount":5}')
    c.render_axn(RefuseTool)
    expect(c.rendered[:status]).to eq(422)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/controller_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::Controller`.

- [ ] **Step 3: Write the mixin**

```ruby
# lib/axn/openapi/controller.rb
# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # Controller skin, for consumers who want their existing auth/filters/middleware stack. The
    # controller owns routing (a Rails route → an action → `render_axn(SomeAxn)`) and supplies the
    # trusted ambient_context; this delegates the run + status/envelope mapping to the shared
    # Dispatcher and renders the result.
    module Controller
      # `ambient_context:` typically carries request-derived trusted data (current_user, request id).
      def render_axn(axn_class, ambient_context: {})
        params = parse_axn_body
        dispatch = Dispatcher.call(axn_class:, params:, ambient_context:)
        render json: dispatch.body, status: dispatch.status
      end

      private

      def parse_axn_body
        body = request.raw_post.to_s
        return {} if body.strip.empty?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {} # a malformed body dispatches as empty params → surfaces as a 400 InboundValidationError
      end
    end
  end
end
```

> NOTE on the malformed-body path: unlike the Router (which owns a dedicated 400 parse envelope), the controller can't easily distinguish "empty" from "malformed" after Rails has consumed the stream, so a malformed body is treated as empty params and surfaces as a normal `InboundValidationError → 400` when required fields are missing. Same status, slightly less specific message. Documented tradeoff.

- [ ] **Step 4: Require it from the main module**

Add to `lib/axn/openapi.rb`: `require_relative "openapi/controller"`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/controller_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi/controller.rb lib/axn/openapi.rb spec/axn/openapi/controller_spec.rb
git commit -m "feat: add controller mixin skin (render_axn)"
```

---

### Task 8: Spec generator

**Files:**
- Create: `lib/axn/openapi/spec_generator.rb`
- Test: `spec/axn/openapi/spec_generator_spec.rb`

**Interfaces:**
- Consumes: `axn_class.input_schema`, `.output_schema`, `.tool_name(:openapi)`, `.description`, `._semantic_hints`, `Axn::OpenAPI.config.info_*`/`path_prefix`.
- Produces: `Axn::OpenAPI::SpecGenerator.new(tools:, path_prefix: nil, info: nil).generate → Hash` (an OpenAPI 3.1.0 document).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/spec_generator_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::SpecGenerator do
  subject(:doc) { described_class.new(tools: [EchoTool, RefuseTool]).generate }

  it "emits an OpenAPI 3.1 document with an info block" do
    expect(doc["openapi"]).to eq("3.1.0")
    expect(doc["info"]).to include("title" => "Axn API", "version" => "1.0.0")
  end

  it "emits one POST path per tool with operationId and schemas" do
    op = doc.dig("paths", "/echo_tool", "post")
    expect(op["operationId"]).to eq("echo_tool")
    expect(op["summary"]).to eq("Echoes a message back.")
    expect(op.dig("requestBody", "content", "application/json", "schema")).to eq(EchoTool.input_schema)
    expect(op.dig("responses", "200", "content", "application/json", "schema")).to eq(EchoTool.output_schema)
  end

  it "references the shared Error component for failure responses" do
    op = doc.dig("paths", "/echo_tool", "post")
    %w[400 422 500].each do |code|
      expect(op.dig("responses", code, "content", "application/json", "schema"))
        .to eq("$ref" => "#/components/schemas/Error")
    end
    expect(doc.dig("components", "schemas", "Error", "type")).to eq("object")
  end

  it "emits semantic hints as a vendor extension" do
    op = doc.dig("paths", "/echo_tool", "post")
    expect(op["x-axn-semantic-hints"]).to eq(["read_only"])
  end

  it "honors a path_prefix" do
    d = described_class.new(tools: [EchoTool], path_prefix: "/axns").generate
    expect(d["paths"]).to have_key("/axns/echo_tool")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/spec_generator_spec.rb`
Expected: FAIL — `uninitialized constant Axn::OpenAPI::SpecGenerator`.

- [ ] **Step 3: Write the generator**

```ruby
# lib/axn/openapi/spec_generator.rb
# frozen_string_literal: true

module Axn
  module OpenAPI
    # Assembles the OpenAPI 3.1 document from axn-core reflection. Near-mechanical: one POST path
    # per tool, requestBody = input_schema, 200 = output_schema, shared Error component for
    # failures, and the semantic hints as an x-axn-semantic-hints vendor extension.
    class SpecGenerator
      ERROR_REF = { "$ref" => "#/components/schemas/Error" }.freeze

      ERROR_SCHEMA = {
        "type" => "object",
        "properties" => {
          "error" => {
            "type" => "object",
            "properties" => {
              "message" => { "type" => "string" },
              "field_errors" => {
                "type" => "array",
                "items" => {
                  "type" => "object",
                  "properties" => { "field" => { "type" => "string" }, "message" => { "type" => "string" } },
                },
              },
            },
            "required" => ["message"],
          },
        },
        "required" => ["error"],
      }.freeze

      def initialize(tools:, path_prefix: nil, info: nil)
        @tools = tools
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @info = info || default_info
      end

      def generate
        {
          "openapi" => "3.1.0",
          "info" => @info,
          "paths" => @tools.to_h { |axn| ["#{@path_prefix}/#{axn.tool_name(:openapi)}", path_item(axn)] },
          "components" => { "schemas" => { "Error" => ERROR_SCHEMA } },
        }
      end

      private

      def default_info
        info = { "title" => Axn::OpenAPI.config.info_title, "version" => Axn::OpenAPI.config.info_version }
        desc = Axn::OpenAPI.config.info_description
        info["description"] = desc if desc
        info
      end

      def path_item(axn)
        op = {
          "operationId" => axn.tool_name(:openapi),
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

      def error_response(description)
        { "description" => description, "content" => { "application/json" => { "schema" => ERROR_REF } } }
      end
    end
  end
end
```

> NOTE: the vendor extension is emitted as **`x-axn-semantic-hints`** (plural, array) because `_semantic_hints` is a set that can hold several hints; the design doc's singular `x-axn-semantic-hint` is superseded here. Update the spec doc's Route-shape section to say plural.

- [ ] **Step 4: Require it from the main module**

Add to `lib/axn/openapi.rb`: `require_relative "openapi/spec_generator"`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/spec_generator_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi/spec_generator.rb lib/axn/openapi.rb spec/axn/openapi/spec_generator_spec.rb
git commit -m "feat: add OpenAPI 3.1 spec generator"
```

---

### Task 9: Module-level API + docs

**Files:**
- Modify: `lib/axn/openapi.rb`
- Modify: `README.md`, `CHANGELOG.md`; Create: `AGENTS-consuming.md`
- Test: `spec/axn/openapi/facade_spec.rb`

**Interfaces:**
- Produces: `Axn::OpenAPI.app(**opts) → App`; `Axn::OpenAPI.spec(tools: nil) → Hash`; `Axn::OpenAPI.tools → Array` (`Axn.tools_for(:openapi)`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/openapi/facade_spec.rb
# frozen_string_literal: true

require "rack/mock"

RSpec.describe "Axn::OpenAPI facade" do
  it ".tools enumerates registered :openapi tools" do
    expect(Axn::OpenAPI.tools).to include(EchoTool)
  end

  it ".spec generates the document for all registered tools by default" do
    expect(Axn::OpenAPI.spec["paths"]).to have_key("/echo_tool")
  end

  it ".app builds a mountable Rack app end-to-end" do
    res = Rack::MockRequest.new(Axn::OpenAPI.app(tools: [EchoTool]))
             .post("/echo_tool", input: '{"message":"hi"}')
    expect(JSON.parse(res.body)).to eq("echoed" => "hi")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/openapi/facade_spec.rb`
Expected: FAIL — `undefined method 'app' for Axn::OpenAPI`.

- [ ] **Step 3: Add the facade methods to the module**

Add inside `module Axn; module OpenAPI` in `lib/axn/openapi.rb` (after `deprecator`):

```ruby
    # The registered :openapi tool set (directory-root grants ∪ `tool :openapi` declarations).
    def self.tools
      Axn.tools_for(:openapi)
    end

    # A mountable Rack app over the given tools (default: every registered :openapi tool).
    def self.app(tools: nil, context: nil, path_prefix: nil, spec_path: nil)
      App.new(tools: tools || self.tools, context:, path_prefix:, spec_path:)
    end

    # The OpenAPI 3.1 document for the given tools (default: every registered :openapi tool).
    def self.spec(tools: nil, path_prefix: nil, info: nil)
      SpecGenerator.new(tools: tools || self.tools, path_prefix:, info:).generate
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/openapi/facade_spec.rb`
Expected: PASS.

- [ ] **Step 5: Write the docs**

Rewrite `README.md` (usage: `mount Axn::OpenAPI.app => "/api"`, controller `include Axn::OpenAPI::Controller` + `render_axn`, config table, the **Scheme-1 status semantics with the 400-vs-422 note** so it doesn't read as an oversight). Add a `## [Unreleased]` block to `CHANGELOG.md` listing the initial feature set. Create `AGENTS-consuming.md` (agent-facing: how to expose an Axn as an HTTP endpoint, the status map, `ambient_context` for auth, config knobs).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/openapi.rb README.md CHANGELOG.md AGENTS-consuming.md spec/axn/openapi/facade_spec.rb
git commit -m "feat: add Axn::OpenAPI.app/.spec/.tools facade + docs"
```

---

### Task 10: Rails integration (mount + controller) in the dummy app

**Files:**
- Modify: `spec_rails/dummy_app/config/routes.rb`
- Create: `spec_rails/dummy_app/app/controllers/loans_controller.rb`
- Test: `spec_rails/*_spec.rb` (request specs against the dummy app)

**Interfaces:**
- Consumes: `Axn::OpenAPI.app`, `Axn::OpenAPI::Controller`. Proves both skins work inside a real Rails router + controller stack (the "works outside Rails" core is already proven by the Rack::MockRequest specs).

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec_rails/mount_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "mounted axn-openapi", type: :request do
  it "serves a tool via the mount" do
    post "/api/echo_tool", params: '{"message":"hi"}', headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(200)
    expect(JSON.parse(response.body)).to eq("echoed" => "hi")
  end

  it "serves the spec via the mount" do
    get "/api/openapi.json"
    expect(JSON.parse(response.body)["paths"]).to have_key("/echo_tool")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../mount_spec.rb`
Expected: FAIL — no route matches `/api/echo_tool`.

- [ ] **Step 3: Mount the app in the dummy routes**

```ruby
# spec_rails/dummy_app/config/routes.rb
Rails.application.routes.draw do
  mount Axn::OpenAPI.app(tools: [EchoTool]) => "/api"
  post "/loans/approve", to: "loans#approve"
end
```

(Ensure `EchoTool` is loadable in the dummy app — either autoloaded from its `app/agent_tools/` or required in an initializer.)

- [ ] **Step 4: Run to verify the mount spec passes**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../mount_spec.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing controller spec**

```ruby
# spec_rails/controller_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "controller mixin", type: :request do
  it "dispatches via render_axn with request-derived ambient_context" do
    post "/loans/approve", params: '{"amount":5}', headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(422) # RefuseTool always fail!s
    expect(JSON.parse(response.body)["error"]["message"]).to eq("Amount too large")
  end
end
```

- [ ] **Step 6: Write the controller**

```ruby
# spec_rails/dummy_app/app/controllers/loans_controller.rb
class LoansController < ActionController::API
  include Axn::OpenAPI::Controller

  def approve
    render_axn(RefuseTool, ambient_context: { actor: request.headers["X-Actor"] })
  end
end
```

- [ ] **Step 7: Run to verify the controller spec passes**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../controller_spec.rb`
Expected: PASS.

- [ ] **Step 8: Full suite + rubocop, then commit**

Run: `bundle exec rake` (Rails-free suite + rubocop) and `bundle exec rake verify` (both suites, if defined).
Expected: PASS, no offenses.

```bash
git add spec_rails/ CHANGELOG.md
git commit -m "test: Rails mount + controller integration in dummy app"
```

---

## Self-Review

**1. Spec coverage** (design doc → task):
- Three skins (dispatcher/Rack/controller/spec-gen) → Tasks 4, 6, 7, 8. ✅
- Membership `tools_for(:openapi)` + `tool_roots` → Task 1. ✅
- Bare-success / enveloped-error → Task 4 (Dispatcher). ✅
- `serialize_exposed` + strict `Object#to_s` guard (config) → Task 3. ✅
- Status Scheme 1 via Invoker `input_invalid?` (400 validation, 422 fail!, 500 unexpected/unserializable), 404/405/400-parse → Tasks 4 (dispatch) + 5 (routing). ✅
- Route shape: flat mount-rooted, `path_prefix`, `GET /openapi.json`, all-POST → Tasks 5, 6. ✅
- `x-axn-semantic-hints` vendor extension, `operationId`, summary → Task 8. ✅ (emitted plural — see note; update spec doc.)
- `reject_undeclared_inputs` (default lenient), `strict_serialization`, `info` config → Tasks 1, 3, 4, 8. ✅
- `ambient_context` auth seam → Tasks 6 (`context:` proc), 7 (`ambient_context:` arg), fixture `ContextEchoTool`. ✅
- Works-outside-Rails core proven by `Rack::MockRequest` (Task 6) + pure-Ruby units; Rails proven separately (Task 10). ✅
- Versioning: **none in v1** — no task, by design (deferred to PRO-2955). ✅
- Deep-subfield reflection caveat: inherited from core `input_schema`; documented in README (Task 9). No extra spec-gen warning in v1 (open question — see handoff).

**2. Placeholder scan:** No TBD/TODO; every code step has complete code. ✅

**3. Type consistency:** `Dispatch(status, body)` used identically in Tasks 4–7. `Serializer.serialize(result, field_configs, strict:)` signature matches its callers. `Router.new(tools:, path_prefix:, spec_path:, spec_provider:)` matches App's construction. `axn.tool_name(:openapi)` used consistently in Router/SpecGenerator. `_semantic_hints` (leading underscore) matches core. ✅

**Fixes applied inline:** Router takes a `spec_provider:` callable so Task 5 is testable before Task 8 exists; App wires the real `SpecGenerator` (Task 6/9). `x-axn-semantic-hint` → `x-axn-semantic-hints` (plural array) to match the multi-hint reality.

**One open item for the user (non-blocking):** whether to surface the core `input_schema` deep-subfield drop as a spec-generation-time warning in v1 (design doc left this open) — currently plan only documents it. Easy to add as a Task 8 step if wanted.
