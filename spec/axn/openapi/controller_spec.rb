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

  describe "a tool that declares allowed_callers" do
    it "refuses to dispatch without a principal: — the controller skin must not fail open" do
      c = controller_class.new('{"company_uuid":"c-1"}')
      expect { c.render_axn(CredentialsTool, mount: :credentials) }.to raise_error(Axn::OpenAPI::Error, /CredentialsTool.*principal:/)
    end

    it "dispatches an allowed principal" do
      c = controller_class.new('{"company_uuid":"c-1"}')
      c.render_axn(CredentialsTool, mount: :credentials, principal: "data_pipeline", ambient_context: { caller_id: "data_pipeline" })
      expect(c.rendered[:status]).to eq(200)
    end

    it "renders 403 for a principal off the list, recording the denial" do
      c = controller_class.new('{"company_uuid":"c-1"}')
      events = capture_axn_calls { c.render_axn(CredentialsTool, mount: :credentials, principal: "ops") }
      expect(c.rendered).to eq(json: { "error" => { "message" => "Forbidden" } }, status: 403)
      expect(axn_call_for(Axn::OpenAPI::Authorize, events)[:outcome]).to eq("failure")
    end
  end

  it "refuses a tool bound to a mount unless render_axn names that mount (it would bypass the mount's auth)" do
    c = controller_class.new("")
    expect { c.render_axn(CredentialsPingTool) }.to raise_error(Axn::OpenAPI::Error, /CredentialsPingTool.*mount: :credentials/)
    expect { c.render_axn(CredentialsPingTool, mount: :other) }.to raise_error(Axn::OpenAPI::Error, /mount: :credentials/)
    expect { c.render_axn(EchoTool, mount: :credentials) }.to raise_error(Axn::OpenAPI::Error, /EchoTool/)
  end

  it "checks a principal: against a tool with no allowlist too (any principal is admitted)" do
    c = controller_class.new("")
    c.render_axn(CredentialsPingTool, mount: :credentials, principal: "anyone")
    expect(c.rendered[:status]).to eq(200)
  end
end
