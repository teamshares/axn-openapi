# frozen_string_literal: true

require "rack/mock"

RSpec.describe "documented security" do
  let(:bearer) { Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "k1", "ops" => "k2" }) }
  let(:api_key) { Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "k3" }, header: "X-API-Key") }
  let(:jwt) do
    Axn::OpenAPI.documented_auth(->(_req) { true }, security_scheme: { type: "http", scheme: "bearer", bearerFormat: "JWT" }, name: "jwt")
  end

  def doc(**opts) = Axn::OpenAPI.spec(mount: :credentials, **opts)
  def responses(document, path) = document["paths"][path]["post"]["responses"]

  it "publishes a Bearer mount's scheme and requires it globally" do
    document = doc(auth: bearer)
    expect(document["components"]["securitySchemes"]).to eq("bearerAuth" => { "type" => "http", "scheme" => "bearer" })
    expect(document["security"]).to eq([{ "bearerAuth" => [] }])
    expect(document).to be_a_valid_openapi_document
  end

  it "lists any-of strategies as security alternatives" do
    document = doc(auth: [api_key, bearer, jwt])
    expect(document["security"]).to eq([{ "apiKeyAuth" => [] }, { "bearerAuth" => [] }, { "jwt" => [] }])
    expect(document["components"]["securitySchemes"]["apiKeyAuth"]).to eq("type" => "apiKey", "in" => "header", "name" => "X-API-Key")
    expect(document["components"]["securitySchemes"]["jwt"]).to include("bearerFormat" => "JWT")
    expect(document).to be_a_valid_openapi_document
  end

  it "documents 401 on every operation, and 403 only where a tool declares allowed_callers" do
    document = doc(auth: bearer)
    expect(responses(document, "/credentials_tool/v1").keys).to include("401", "403")
    expect(responses(document, "/credentials_ping_tool/v1").keys).to include("401")
    expect(responses(document, "/credentials_ping_tool/v1").keys).not_to include("403")
  end

  it "documents 403 everywhere when the mount has an authorize: callable" do
    document = doc(auth: bearer, authorize: ->(*) { true })
    expect(responses(document, "/credentials_ping_tool/v1").keys).to include("403")
  end

  it "documents no security at all for an unauthenticated document" do
    document = Axn::OpenAPI.spec(tools: [EchoTool])
    expect(document).not_to have_key("security")
    expect(document["components"]).not_to have_key("securitySchemes")
    expect(responses(document, "/echo_tool/v1").keys).not_to include("401", "403")
  end

  it "merges a per-mount info: over the configured defaults" do
    document = doc(auth: bearer, info: { title: "Credentials API", description: "For data pipelines" })
    expect(document["info"]).to eq("title" => "Credentials API", "version" => "1.0.0", "description" => "For data pipelines")
  end

  it "serves the same security from a mounted app" do
    app = Axn::OpenAPI.app(auth: bearer, mount: :credentials, info: { title: "Credentials API" })
    res = Rack::MockRequest.new(app).get("/openapi.json", "HTTP_AUTHORIZATION" => "Bearer k2")
    served = JSON.parse(res.body)
    expect(served["security"]).to eq([{ "bearerAuth" => [] }])
    expect(served["info"]["title"]).to eq("Credentials API")
    expect(served).to be_a_valid_openapi_document
  end
end
