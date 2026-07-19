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
