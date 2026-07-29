# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Dispatcher do
  # Mirror the skins' render boundary: Dispatcher.call builds the dispatch; ensure_encodable is the
  # JSON-encodability gate the App/Controller apply before rendering (so encode-failure cases 500).
  def dispatch(axn, params) = described_class.ensure_encodable(described_class.call(axn_class: axn, params:))

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

  it "returns 500 when a successful result exposes an opaque value (reject_opaque_exposed_values)" do
    d = dispatch(OpaqueTool, {})
    expect(d.status).to eq(500)
  end

  # `reject_opaque_exposed_values` is `overridable:`, so it resolves per-tool through the override
  # store rather than straight off the gem-wide config — matching axn-mcp, where the same knob is
  # settable per tool. Both directions are pinned: a tool serving a legacy shape can opt out without
  # loosening the whole API, and a stricter tool can opt in under a lenient default.
  describe "per-tool override via configure(:openapi)" do
    it "lets a single tool opt out while the gem-wide default stays strict" do
      lenient = Class.new do
        include Axn

        configure(:openapi) { |c| c.reject_opaque_exposed_values = false }
        exposes :thing
        def call = expose(thing: OpaqueValue.new)
      end

      expect(Axn::OpenAPI.config.reject_opaque_exposed_values).to be(true)
      expect(dispatch(lenient, {}).status).to eq(200)
      # The gem-wide default is untouched for every other tool.
      expect(dispatch(OpaqueTool, {}).status).to eq(500)
    end

    it "lets a per-tool true win over a lenient gem-wide setting" do
      strict = Class.new do
        include Axn

        configure(:openapi) { |c| c.reject_opaque_exposed_values = true }
        exposes :thing
        def call = expose(thing: OpaqueValue.new)
      end

      Axn::OpenAPI.config.reject_opaque_exposed_values = false
      expect(dispatch(strict, {}).status).to eq(500)
      expect(dispatch(OpaqueTool, {}).status).to eq(200)
    ensure
      Axn::OpenAPI.config.reject_opaque_exposed_values = true
    end
  end

  # Core raises these regardless of reject_opaque, and they are raised where an adapter that skipped
  # its own pre-pass would otherwise have shipped a broken body. Pinned at the Dispatcher (not just
  # the Serializer) because the risk of removing the pre-pass was an ESCAPED exception rather than a
  # wrong status: these must surface as the documented generic 500, not raise out of the Rack app.
  it "returns 500 (no leak) when exposed Hash keys collapse to one JSON property" do
    klass = Class.new do
      include Axn

      exposes :data
      def call = expose(data: { :id => 1, "id" => 2 })
    end
    d = dispatch(klass, {})
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "returns 500 (no leak) when a successful result exposes a cyclic container" do
    klass = Class.new do
      include Axn

      exposes :items
      def call
        a = [1]
        a << a
        expose(items: a)
      end
    end
    d = dispatch(klass, {})
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "returns 500 (no leak) when a successful result exposes a non-JSON-encodable number" do
    klass = Class.new do
      include Axn

      exposes :ratio, type: Float
      def call = expose(ratio: Float::INFINITY)
    end
    d = dispatch(klass, {})
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "returns 500 (no leak) when a successful result exposes a string JSON can't encode (invalid UTF-8)" do
    klass = Class.new do
      include Axn

      exposes :blob, type: String
      def call = expose(blob: "\xFF\xFE".b)
    end
    d = dispatch(klass, {})
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "returns 500 (no leak) when a value's own projection raises during serialization" do
    exploding = Class.new { def to_h = raise("boom in to_h") }
    klass = Class.new do
      include Axn

      exposes :thing
      define_method(:call) { expose(thing: exploding.new) }
    end
    d = dispatch(klass, {})
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "maps a SystemStackError during serialization to a generic 500 (not a StandardError)" do
    # e.g. a self-referential structure recursing past the guard; backstop so it never escapes.
    allow(Axn::OpenAPI::Serializer).to receive(:serialize).and_raise(SystemStackError)
    d = dispatch(EchoTool, { "message" => "hi" })
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "maps any non-encodable body (including a failure/validation envelope) to a generic 500" do
    bad = Axn::OpenAPI::Dispatch.new(422, { "error" => { "message" => "bad: \xFF\xFE".b } })
    result = described_class.ensure_encodable(bad)
    expect(result.status).to eq(500)
    expect(result.body).to eq("error" => { "message" => "Internal Server Error" })
  end

  it "returns 500 (no leak) when a fail! message isn't JSON-encodable (invalid UTF-8)" do
    klass = Class.new do
      include Axn

      def call = fail!("bad: \xFF\xFE".b)
    end
    d = dispatch(klass, {})
    expect(d.status).to eq(500)
    expect(d.body).to eq("error" => { "message" => "Internal Server Error" })
  end
end
