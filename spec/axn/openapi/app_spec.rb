# frozen_string_literal: true

require "rack/mock"

RSpec.describe Axn::OpenAPI::App do
  let(:app) { described_class.new(tools: [EchoTool], spec_provider: -> { { "openapi" => "3.1.0" } }) }
  let(:mock) { Rack::MockRequest.new(app) }

  it "serves a tool over a real Rack request" do
    res = mock.post("/echo_tool/v1", input: '{"message":"hi"}', "CONTENT_TYPE" => "application/json")
    expect(res.status).to eq(200)
    expect(JSON.parse(res.body)).to eq("echoed" => "hi")
    expect(res.headers["content-type"]).to eq("application/json")
  end

  it "returns 405 with an Allow header for a wrong verb on a tool path" do
    res = mock.get("/echo_tool/v1")
    expect(res.status).to eq(405)
    expect(res.headers["allow"]).to eq("POST")
  end

  it "serves the spec" do
    res = mock.get("/openapi.json")
    expect(JSON.parse(res.body)).to eq("openapi" => "3.1.0")
  end

  it "passes ambient_context built from env" do
    ctx_app = described_class.new(tools: [ContextEchoTool], context: ->(env) { { actor: env["HTTP_X_ACTOR"] } })
    res = Rack::MockRequest.new(ctx_app).post("/context_echo_tool/v1", input: "{}", "HTTP_X_ACTOR" => "alice")
    expect(JSON.parse(res.body)).to eq("actor" => "alice")
  end

  it "forwards an instance path_prefix into the served spec" do
    app = described_class.new(tools: [EchoTool], path_prefix: "/axns")
    res = Rack::MockRequest.new(app).get("/axns/openapi.json")
    expect(res.status).to eq(200)
    expect(JSON.parse(res.body)["paths"]).to have_key("/axns/echo_tool/v1")
  end

  it "serves every version when tools default to the all-versions facade" do
    allow(Axn::OpenAPI).to receive(:tools).and_return([CalcV1Tool, CalcV2Tool])
    app = described_class.new # no explicit tools:
    mock = Rack::MockRequest.new(app)
    expect(mock.post("/calc/v1", input: '{"n":5}').status).to eq(200)
    expect(mock.post("/calc/v2", input: '{"n":5}').status).to eq(200)
  end

  it "publishes the Rack mount base (SCRIPT_NAME) as the served spec's servers entry" do
    app = described_class.new(tools: [EchoTool]) # default provider -> real SpecGenerator
    res = Rack::MockRequest.new(app).get("/openapi.json", "SCRIPT_NAME" => "/api")
    doc = JSON.parse(res.body)
    expect(doc["servers"]).to eq([{ "url" => "/api" }])
    expect(doc["paths"]).to have_key("/echo_tool/v1")
  end

  it "captures the default path_prefix once so routing and the served doc can't split on a later config change" do
    original = Axn::OpenAPI.config.path_prefix
    Axn::OpenAPI.config.path_prefix = "/at-build"
    app = described_class.new(tools: [EchoTool]) # default prefix + default provider
    Axn::OpenAPI.config.path_prefix = "/changed-after"
    mock = Rack::MockRequest.new(app)

    expect(mock.post("/at-build/echo_tool/v1", input: '{"message":"hi"}').status).to eq(200)
    doc = JSON.parse(mock.get("/at-build/openapi.json").body)
    expect(doc["paths"]).to have_key("/at-build/echo_tool/v1")
  ensure
    Axn::OpenAPI.config.path_prefix = original
  end

  it "snapshots the tools list so mutating the passed array can't split routes from the doc" do
    tools = [EchoTool]
    app = described_class.new(tools:) # default provider -> real SpecGenerator over @tools
    tools.clear # caller mutates their array after construction
    mock = Rack::MockRequest.new(app)

    expect(mock.post("/echo_tool/v1", input: '{"message":"hi"}').status).to eq(200)
    doc = JSON.parse(mock.get("/openapi.json").body)
    expect(doc["paths"]).to have_key("/echo_tool/v1")
  end

  it "copies the resolved prefix so mutating the source string after build doesn't drift it" do
    prefix = +"/mut" # a mutable String
    app = described_class.new(tools: [EchoTool], path_prefix: prefix)
    prefix << "ated" # caller mutates their string after construction
    mock = Rack::MockRequest.new(app)

    expect(mock.post("/mut/echo_tool/v1", input: '{"message":"hi"}').status).to eq(200)
    expect(JSON.parse(mock.get("/mut/openapi.json").body)["paths"]).to have_key("/mut/echo_tool/v1")
  end

  it "gates non-encodable non-Dispatcher bodies (e.g. a bad spec doc) at the render boundary → 500" do
    bad_provider = ->(_base) { { "x" => "bad: \xFF\xFE".b } }
    app = described_class.new(tools: [EchoTool], spec_provider: bad_provider)
    res = Rack::MockRequest.new(app).get("/openapi.json")
    expect(res.status).to eq(500)
    expect(JSON.parse(res.body)).to eq("error" => { "message" => "Internal Server Error" })
  end
end
