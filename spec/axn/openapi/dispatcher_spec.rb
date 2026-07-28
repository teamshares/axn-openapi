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
end
