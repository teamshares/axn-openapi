# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Router do
  subject(:router) { described_class.new(tools: [EchoTool, CalcV1Tool, CalcV2Tool], spec_provider: -> { { "openapi" => "3.1.0" } }) }

  def route(method, path, body: "", ctx: {})
    router.route(http_method: method, path:, raw_body: body, ambient_context: ctx)
  end

  it "routes POST /<tool>/v1 for a single-version tool" do
    d = route("POST", "/echo_tool/v1", body: '{"message":"hi"}')
    expect(d.status).to eq(200)
    expect(d.body).to eq("echoed" => "hi")
  end

  it "routes each version to its own Axn" do
    # Shared fixtures (spec/support/versioned_tools.rb): CalcV1Tool exposes :value, CalcV2Tool :doubled
    # (`result` is a reserved exposure name). Both set their name via `axn_name "calc"`, not `tool_name`.
    expect(route("POST", "/calc/v1", body: '{"n":5}').body).to eq("value" => 5)
    expect(route("POST", "/calc/v2", body: '{"n":5}').body).to eq("doubled" => 10)
  end

  it "has no bare path" do
    expect(route("POST", "/echo_tool", body: '{"message":"hi"}').status).to eq(404)
  end

  it "404s an unknown version of a known tool with a pointer to the latest" do
    d = route("POST", "/calc/v3", body: '{"n":1}')
    expect(d.status).to eq(404)
    expect(d.body["error"]["message"]).to include("/calc/v2")
  end

  it "includes the mount base (script_name) in the 404 version pointer" do
    d = router.route(http_method: "POST", path: "/calc/v3", raw_body: '{"n":1}', script_name: "/api")
    expect(d.body["error"]["message"]).to include("/api/calc/v2")
  end

  it "404s an unknown tool with no pointer" do
    d = route("POST", "/nope/v1", body: "{}")
    expect(d.status).to eq(404)
    expect(d.body["error"]["message"]).not_to include("/v")
  end

  it "serves the spec at GET /openapi.json" do
    expect(route("GET", "/openapi.json").body).to eq("openapi" => "3.1.0")
  end

  it "405s a wrong verb on a known versioned path, with Allow: POST" do
    d = route("GET", "/echo_tool/v1")
    expect(d.status).to eq(405)
    expect(d.headers).to eq("allow" => "POST")
  end

  it "405s a wrong verb on the spec path, with Allow: GET" do
    d = route("POST", "/openapi.json", body: "{}")
    expect(d.status).to eq(405)
    expect(d.headers).to eq("allow" => "GET")
  end

  it "400s a malformed JSON body" do
    expect(route("POST", "/echo_tool/v1", body: "{not json").status).to eq(400)
  end

  it "honors a path_prefix" do
    r = described_class.new(tools: [EchoTool], path_prefix: "/axns")
    expect(r.route(http_method: "POST", path: "/axns/echo_tool/v1", raw_body: '{"message":"hi"}').status).to eq(200)
  end

  it "fails loud when spec_path collides with a tool route" do
    expect { described_class.new(tools: [EchoTool], spec_path: "/echo_tool/v1") }
      .to raise_error(Axn::OpenAPI::Error, /collides/)
  end

  # subject's zero-arg `-> { ... }` provider (exercised by "serves the spec" above) proves the
  # documented zero-arity form still works after SCRIPT_NAME threading; this covers the one-arg form.
  it "passes the request's script_name to a one-arg spec provider" do
    seen = nil
    provider = lambda do |base|
      seen = base
      { "servers" => [{ "url" => base }] }
    end
    r = described_class.new(tools: [EchoTool], spec_provider: provider)
    d = r.route(http_method: "GET", path: "/openapi.json", raw_body: "", script_name: "/api")
    expect(seen).to eq("/api")
    expect(d.body).to eq("servers" => [{ "url" => "/api" }])
  end

  it "supports a plain callable-object spec provider (def call), reading arity off #call" do
    provider = Object.new
    def provider.call(base) = { "servers" => [{ "url" => base }] }
    r = described_class.new(tools: [EchoTool], spec_provider: provider)
    d = r.route(http_method: "GET", path: "/openapi.json", raw_body: "", script_name: "/api")
    expect(d.body).to eq("servers" => [{ "url" => "/api" }])
  end
end
