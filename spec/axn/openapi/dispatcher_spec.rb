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

  # The 200 body is whatever Axn::Extensions::Serialization.render renders, so the exhaustive
  # per-defect matrix (which values are opaque, how cycles/collisions/non-finite numbers are detected)
  # lives in axn core's own specs — duplicating it here would re-create, in test form, exactly the
  # parallel walk this gem deleted. What these pin is that the adapter reaches that renderer at all
  # and hands its output through untouched: a non-String leaf arrives wire-shaped, not `#inspect`ed,
  # and nesting is walked rather than stringified whole.
  describe "the success body core renders" do
    it "renders a non-String leaf in its schema-aligned wire form" do
      klass = Class.new do
        include Axn

        exposes :n, type: Integer
        exposes :t, type: Time
        def call = expose(n: 3, t: Time.utc(2020, 1, 2, 3, 4, 5))
      end
      expect(dispatch(klass, {}).body).to eq("n" => 3, "t" => "2020-01-02T03:04:05Z")
    end

    it "renders a nested Hash/Array of safe leaves" do
      klass = Class.new do
        include Axn

        exposes :data
        def call = expose(data: { "items" => [1, 2], "when" => Time.utc(2020, 1, 1) })
      end
      expect(dispatch(klass, {}).body)
        .to eq("data" => { "items" => [1, 2], "when" => "2020-01-01T00:00:00Z" })
    end

    # The two ways strict rejection could over-fire and turn a fine result into a 500: a value whose
    # author DID declare a rendering (so it isn't opaque), and a graph that repeats a reference
    # without cycling (so it isn't self-referential).
    it "renders a value with a meaningful custom to_s rather than rejecting it" do
      money = Class.new { def to_s = "$4.00" }
      klass = Class.new do
        include Axn

        exposes :price
        define_method(:call) { expose(price: money.new) }
      end
      expect(dispatch(klass, {}).body).to eq("price" => "$4.00")
    end

    it "renders a shared but acyclic reference (diamond) rather than reporting a cycle" do
      shared = { "x" => 1 }
      klass = Class.new do
        include Axn

        exposes :data
        define_method(:call) { expose(data: { "a" => shared, "b" => shared }) }
      end
      expect(dispatch(klass, {}).body).to eq("data" => { "a" => { "x" => 1 }, "b" => { "x" => 1 } })
    end
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
  # The 500 log line is an operator's only pointer to WHY an otherwise-successful call failed, and the
  # value it reports on is resolved per-tool — so a hint naming only the gem-wide setter is a dead end
  # whenever a `configure(:openapi)` override is what's in effect. Pinned because that is exactly how it
  # regressed once: the hint was accurate until the setting became `overridable:`.
  describe "the opaque-rejection log hint" do
    # A real Logger over a StringIO rather than a double: axn's own call logger writes :info lines
    # through this same object, so a verifying double would fail on those instead of on what's asserted.
    def captured_log_for(axn)
      io = StringIO.new
      allow(Axn.config).to receive(:logger).and_return(Logger.new(io))
      dispatch(axn, {})
      io.string
    end

    it "names the offending tool and BOTH config levels, not just the gem-wide setter" do
      line = captured_log_for(OpaqueTool)

      expect(line).to include("OpaqueTool")                          # which action to go look at
      expect(line).to include("configure(:openapi)")                 # the per-tool level, which wins
      expect(line).to include("Axn::OpenAPI.config.reject_opaque_exposed_values") # the gem-wide level
    end

    it "omits the hint entirely when the rejection cannot be opaque-related" do
      cyclic = Class.new do
        include Axn

        configure(:openapi) { |c| c.reject_opaque_exposed_values = false }
        exposes :items
        def call
          a = [1]
          a << a
          expose(items: a)
        end
      end

      line = captured_log_for(cyclic)
      expect(line).to include("UnserializableValue")
      expect(line).not_to include("reject_opaque_exposed_values")
    end
  end

  # The runtime half of the pair asserted in spec_generator_spec: a per-tool override must change what
  # the dispatcher actually enforces, not just what the document advertises.
  it "honors a per-tool reject_undeclared_inputs override at runtime" do
    strict = Class.new do
      include Axn

      configure(:openapi) { |c| c.reject_undeclared_inputs = true }
      expects :message, type: String
      exposes :echoed
      def call = expose(echoed: message)
    end

    expect(Axn::OpenAPI.config.reject_undeclared_inputs).to be(false)
    expect(dispatch(strict, { "message" => "hi", "surprise" => 1 }).status).to eq(400)
    expect(dispatch(strict, { "message" => "hi" }).status).to eq(200)
  end

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
  # its own pre-pass would otherwise have shipped a broken body. Pinned here because the risk of
  # removing the pre-pass was an ESCAPED exception rather than a wrong status: these must surface as
  # the documented generic 500, not raise out of the Rack app.
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
    allow(Axn::Extensions::Serialization).to receive(:render).and_raise(SystemStackError)
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
