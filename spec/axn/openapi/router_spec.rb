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
