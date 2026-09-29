# frozen_string_literal: true

require "rack/mock"

RSpec.describe "path_segment_style" do
  around do |example|
    original = Axn::OpenAPI.config.path_segment_style
    example.run
  ensure
    Axn::OpenAPI.config.path_segment_style = original
  end

  it "defaults to :snake, serving the tool_name as-is" do
    expect(Axn::OpenAPI.config.path_segment_style).to eq(:snake)
    expect(Axn::OpenAPI::RouteTable.build(tools: [ListIntegrationsTool], path_prefix: "").first.path).to eq("/list_integrations/v1")
  end

  it "accepts only :snake or :kebab" do
    expect { Axn::OpenAPI.config.path_segment_style = :camel }.to raise_error(ArgumentError, /path_segment_style/)
    expect { Axn::OpenAPI.config.path_segment_style = "kebab" }.to raise_error(ArgumentError)
  end

  describe ":kebab" do
    before { Axn::OpenAPI.config.path_segment_style = :kebab }

    it "hyphenates the path segment but keeps operationId and tool_name snake_case" do
      entry = Axn::OpenAPI::RouteTable.build(tools: [ListIntegrationsTool], path_prefix: "/axns").first
      expect(entry.path).to eq("/axns/list-integrations/v1")
      expect(entry.operation_id).to eq("list_integrations_v1")
      expect(ListIntegrationsTool.tool_name(:openapi)).to eq("list_integrations")
    end

    it "routes the kebab path, and no longer the snake one" do
      mock = Rack::MockRequest.new(Axn::OpenAPI.app(auth: :none, tools: [ListIntegrationsTool]))
      expect(JSON.parse(mock.post("/list-integrations/v1", input: "").body)).to eq("count" => 2)
      expect(mock.post("/list_integrations/v1", input: "").status).to eq(404)
    end

    it "points a 404 for an unknown version at the kebab path of the latest version" do
      mock = Rack::MockRequest.new(Axn::OpenAPI.app(auth: :none, tools: [ListIntegrationsTool]))
      body = JSON.parse(mock.post("/list-integrations/v9", input: "").body)
      expect(body["error"]["message"]).to eq("Unknown version for tool 'list-integrations'. Latest available: /list-integrations/v1.")
    end

    it "documents the kebab paths with snake operationIds" do
      doc = Axn::OpenAPI.spec(tools: [ListIntegrationsTool])
      expect(doc["paths"].keys).to eq(["/list-integrations/v1"])
      expect(doc["paths"]["/list-integrations/v1"]["post"]["operationId"]).to eq("list_integrations_v1")
      expect(doc).to be_a_valid_openapi_document
    end

    it "is captured when an app is built, so routing and its served document can't drift apart" do
      app = Axn::OpenAPI.app(auth: :none, tools: [ListIntegrationsTool])
      Axn::OpenAPI.config.path_segment_style = :snake
      mock = Rack::MockRequest.new(app)
      expect(mock.post("/list-integrations/v1", input: "").status).to eq(200)
      expect(JSON.parse(mock.get("/openapi.json").body)["paths"].keys).to eq(["/list-integrations/v1"])
    end
  end
end
