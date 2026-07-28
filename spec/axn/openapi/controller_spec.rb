# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Controller do
  # Minimal stand-in for an ActionController: exposes #request.raw_post and captures #render.
  let(:controller_class) do
    Class.new do
      include Axn::OpenAPI::Controller

      attr_accessor :rendered

      def initialize(body) = @body = body
      def request = Struct.new(:raw_post).new(@body)
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

  it "renders a 400 for a malformed body instead of dispatching {} (matches the mount router)" do
    # ContextEchoTool has no required inputs, so a silently-emptied body would otherwise 200.
    c = controller_class.new("{not json")
    c.render_axn(ContextEchoTool)
    expect(c.rendered[:status]).to eq(400)
    expect(c.rendered[:json]).to eq("error" => { "message" => "Malformed JSON request body" })
  end

  it "renders a 400 for a non-object JSON body" do
    c = controller_class.new("[1,2,3]")
    c.render_axn(ContextEchoTool)
    expect(c.rendered[:status]).to eq(400)
  end
end
