# frozen_string_literal: true

# The Serializer is a pass-through to Axn::Reflection::Values.serialize_exposed, so the exhaustive
# per-defect matrix (which values are opaque, how cycles/collisions/non-finite numbers are detected)
# lives in axn core's own specs — duplicating it here would re-create, in test form, exactly the
# parallel walk this gem deleted. What is tested here is the seam: that the adapter forwards
# `reject_opaque` faithfully, and that core's rejections surface as the error the Dispatcher rescues.
RSpec.describe Axn::OpenAPI::Serializer do
  def serialize(axn, reject_opaque: true)
    result = axn.call
    described_class.serialize(result, axn.external_field_configs, reject_opaque:)
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

  it "serializes a nested Hash/Array of safe leaves without raising" do
    klass = Class.new do
      include Axn

      exposes :data
      def call = expose(data: { "items" => [1, 2], "when" => Time.utc(2020, 1, 1) })
    end
    expect(serialize(klass)["data"]).to eq("items" => [1, 2], "when" => "2020-01-01T00:00:00Z")
  end

  it "raises core's UnserializableValue on an opaque value when reject_opaque" do
    expect { serialize(OpaqueTool) }
      .to raise_error(Axn::Reflection::UnserializableValue, /thing/)
  end

  it "forwards reject_opaque: false, matching MCP leniency" do
    expect { serialize(OpaqueTool, reject_opaque: false) }.not_to raise_error
  end

  it "names the offending field path for a value nested inside a Hash" do
    klass = Class.new do
      include Axn

      exposes :data
      def call = expose(data: { "bad" => OpaqueValue.new })
    end
    expect { serialize(klass) }
      .to raise_error(Axn::Reflection::UnserializableValue, /data\.bad/)
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

  # The rejections below are core's UNCONDITIONAL tier — not gated on reject_opaque, because what they
  # would render is not JSON at all. Asserted with reject_opaque: false precisely to pin that: turning
  # this gem's leniency knob off must not buy back a body JSON.generate would refuse (or one that
  # silently dropped a value).
  it "rejects a self-referential exposure even when reject_opaque is false" do
    klass = Class.new do
      include Axn

      exposes :items
      def call
        a = [1]
        a << a
        expose(items: a)
      end
    end
    expect { serialize(klass, reject_opaque: false) }
      .to raise_error(Axn::Reflection::UnserializableValue, /self-referential|cycle/i)
  end

  it "rejects keys that collapse to one JSON property even when reject_opaque is false" do
    klass = Class.new do
      include Axn

      exposes :data
      def call = expose(data: { :id => 1, "id" => 2 })
    end
    expect { serialize(klass, reject_opaque: false) }
      .to raise_error(Axn::Reflection::UnserializableValue, /collapse|same JSON property/i)
  end

  it "rejects a non-finite Float even when reject_opaque is false" do
    klass = Class.new do
      include Axn

      exposes :ratio, type: Float
      def call = expose(ratio: Float::INFINITY)
    end
    expect { serialize(klass, reject_opaque: false) }
      .to raise_error(Axn::Reflection::UnserializableValue, /ratio/)
  end

  it "does not false-positive on a shared but acyclic reference (diamond)" do
    shared = { "x" => 1 }
    klass = Class.new do
      include Axn

      exposes :data
      define_method(:call) { expose(data: { "a" => shared, "b" => shared }) }
    end
    expect { serialize(klass) }.not_to raise_error
  end
end
