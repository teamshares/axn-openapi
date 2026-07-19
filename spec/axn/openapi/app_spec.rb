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

  it "forwards an instance path_prefix into the served spec" do
    app = described_class.new(tools: [EchoTool], path_prefix: "/axns")
    res = Rack::MockRequest.new(app).get("/axns/openapi.json")
    expect(res.status).to eq(200)
    expect(JSON.parse(res.body)["paths"]).to have_key("/axns/echo_tool")
  end
end
