# frozen_string_literal: true

require "rack/mock"
require "yaml"

RSpec.describe "YAML document output" do
  it "renders .spec as YAML with string keys, equal to the JSON a client receives" do
    yaml = Axn::OpenAPI.spec_yaml(tools: [EchoTool, CalcV1Tool, CalcV2Tool])
    json = JSON.parse(JSON.generate(Axn::OpenAPI.spec(tools: [EchoTool, CalcV1Tool, CalcV2Tool])))
    expect(YAML.safe_load(yaml)).to eq(json)
    expect(yaml).not_to include(":required") # no Ruby Symbol keys leak into the YAML
  end

  describe "served by a mount" do
    let(:strategy) { Axn::Extensions::Auth::Bearer.new(keys: { "ops" => "ops-key" }) }
    let(:app) { Axn::OpenAPI.app(auth: strategy, tools: [EchoTool]) }
    let(:mock) { Rack::MockRequest.new(app) }

    it "serves the document at /openapi.yaml as application/yaml" do
      res = mock.get("/openapi.yaml", "HTTP_AUTHORIZATION" => "Bearer ops-key", "SCRIPT_NAME" => "/api")
      expect(res.status).to eq(200)
      expect(res.headers["content-type"]).to eq("application/yaml")
      json = JSON.parse(mock.get("/openapi.json", "HTTP_AUTHORIZATION" => "Bearer ops-key", "SCRIPT_NAME" => "/api").body)
      expect(YAML.safe_load(res.body)).to eq(json)
    end

    it "is authenticated like the JSON document, and public with it under public_spec" do
      expect(mock.get("/openapi.yaml").status).to eq(401)
      public_app = Axn::OpenAPI.app(auth: strategy, tools: [EchoTool], public_spec: true)
      expect(Rack::MockRequest.new(public_app).get("/openapi.yaml").status).to eq(200)
    end

    it "answers a non-GET with a JSON 405 + Allow" do
      res = mock.post("/openapi.yaml", "HTTP_AUTHORIZATION" => "Bearer ops-key")
      expect(res.status).to eq(405)
      expect(res.headers["allow"]).to eq("GET")
      expect(res.headers["content-type"]).to eq("application/json")
    end

    it "honors path_prefix" do
      prefixed = Axn::OpenAPI.app(auth: :none, tools: [EchoTool], path_prefix: "/axns")
      expect(Rack::MockRequest.new(prefixed).get("/axns/openapi.yaml").status).to eq(200)
    end
  end

  describe "the spec_yaml_path setting" do
    around do |example|
      original = Axn::OpenAPI.config.spec_yaml_path
      example.run
    ensure
      Axn::OpenAPI.config.spec_yaml_path = original
    end

    it "moves the route" do
      Axn::OpenAPI.config.spec_yaml_path = "/spec.yml"
      mock = Rack::MockRequest.new(Axn::OpenAPI.app(auth: :none, tools: [EchoTool]))
      expect(mock.get("/spec.yml").status).to eq(200)
      expect(mock.get("/openapi.yaml").status).to eq(404)
    end

    it "turns the route off when nil" do
      Axn::OpenAPI.config.spec_yaml_path = nil
      expect(Rack::MockRequest.new(Axn::OpenAPI.app(auth: :none, tools: [EchoTool])).get("/openapi.yaml").status).to eq(404)
    end

    it "fails loud when it collides with a tool route" do
      Axn::OpenAPI.config.spec_yaml_path = "/echo_tool/v1"
      expect { Axn::OpenAPI.app(auth: :none, tools: [EchoTool]) }.to raise_error(Axn::OpenAPI::Error, /spec_yaml_path.*collides/)
    end

    it "fails loud when it equals spec_path" do
      Axn::OpenAPI.config.spec_yaml_path = "/openapi.json"
      expect { Axn::OpenAPI.app(auth: :none, tools: [EchoTool]) }.to raise_error(Axn::OpenAPI::Error, /spec_yaml_path.*spec_path/)
    end
  end
end
