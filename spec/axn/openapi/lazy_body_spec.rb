# frozen_string_literal: true

require "rack/mock"
require "stringio"

# A rack.input that counts how often it is read.
class CountingInput < StringIO
  attr_reader :reads

  def initialize(...)
    super
    @reads = 0
  end

  def read(...)
    @reads += 1
    super
  end
end

# The request body is caller data of unknown size: an anonymous or refused request must not get it
# buffered. The App reads it only when a tool is actually dispatched (or a strategy asks for it).
RSpec.describe "Lazy request body" do
  let(:strategy) { Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "pipeline-key" }) }
  let(:input) { CountingInput.new('{"message":"hi"}') }

  def call(app, path, method: "POST", token: nil)
    env = Rack::MockRequest.env_for(path, method:)
    env["rack.input"] = input
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    app.call(env)
  end

  let(:app) { Axn::OpenAPI.app(auth: strategy, tools: [EchoTool]) }

  it "does not read the body of an unauthenticated request" do
    status, = call(app, "/echo_tool/v1")
    expect(status).to eq(401)
    expect(input.reads).to eq(0)
  end

  it "does not read the body of a 404, a 405, or a spec request" do
    expect(call(app, "/nope/v1", token: "pipeline-key").first).to eq(404)
    expect(call(app, "/echo_tool/v1", method: "PUT", token: "pipeline-key").first).to eq(405)
    expect(call(app, "/openapi.json", method: "GET", token: "pipeline-key").first).to eq(200)
    expect(input.reads).to eq(0)
  end

  it "does not read the body of a forbidden request" do
    deny = Axn::OpenAPI.app(auth: strategy, tools: [EchoTool], authorize: ->(*) { false })
    expect(call(deny, "/echo_tool/v1", token: "pipeline-key").first).to eq(403)
    expect(input.reads).to eq(0)
  end

  it "reads the body once when a tool is dispatched" do
    status, _headers, body = call(app, "/echo_tool/v1", token: "pipeline-key")
    expect(status).to eq(200)
    expect(JSON.parse(body.join)).to eq("echoed" => "hi")
    expect(input.reads).to eq(1)
  end

  it "still hands the body to a strategy that asks for it, and reuses that read on dispatch" do
    seen = nil
    body_auth = Axn::OpenAPI.documented_auth(
      lambda { |request|
        seen = request.raw_body
        true
      },
      security_scheme: { type: "http", scheme: "bearer" },
    )
    status, = call(Axn::OpenAPI.app(auth: body_auth, tools: [EchoTool]), "/echo_tool/v1")
    expect(status).to eq(200)
    expect(seen).to eq('{"message":"hi"}')
    expect(input.reads).to eq(1)
  end

  it "does not read the body to render inspect" do
    request = Axn::OpenAPI::Request.from_rack(Rack::MockRequest.env_for("/x", method: "POST").merge("rack.input" => input))
    expect(request.inspect).to include("raw_body=[REDACTED]")
    expect(input.reads).to eq(0)
    request.raw_body
    expect(request.inspect).to include("(16b)")
  end
end
