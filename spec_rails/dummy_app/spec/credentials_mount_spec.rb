# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "axn/openapi/testing/rspec"

RSpec.describe "a Bearer-gated credentials mount inside Rails" do
  include Rack::Test::Methods

  def app = Rails.application

  def read(token: nil, body: '{"company_uuid":"c-1"}')
    header "Authorization", "Bearer #{token}" if token
    post "/internal/credentials/integration_credentials/v1", body, "CONTENT_TYPE" => "application/json"
  end

  it "401s without a token, with the Bearer challenge" do
    read
    expect(last_response.status).to eq(401)
    expect(last_response.headers["www-authenticate"]).to eq("Bearer")
  end

  it "403s an authenticated caller that isn't on the tool's allowlist" do
    read(token: "ops-key")
    expect(last_response.status).to eq(403)
  end

  it "serves the allowlisted caller, handing the principal to the tool via context:" do
    read(token: "pipeline-key")
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body))
      .to eq("company_uuid" => "c-1", "read_by" => "data_pipeline", "client_secret_ciphertext" => "ciphertext-b64")
  end

  it "keeps the credentials tool off the general mount" do
    post "/api/integration_credentials/v1", '{"company_uuid":"c-1"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(404)
    get "/api/openapi.json"
    expect(JSON.parse(last_response.body)["paths"].keys).not_to include(a_string_including("integration_credentials"))
  end

  it "gates its OpenAPI document and documents the Bearer scheme" do
    get "/internal/credentials/openapi.json"
    expect(last_response.status).to eq(401)
    header "Authorization", "Bearer ops-key"
    get "/internal/credentials/openapi.json"
    doc = JSON.parse(last_response.body)
    expect(doc["info"]["title"]).to eq("Credentials API")
    expect(doc["security"]).to eq([{ "bearerAuth" => [] }])
    expect(doc["servers"]).to eq([{ "url" => "/internal/credentials" }])
  end

  it "passes the consumer contract checks: a valid document, examples included, and a conforming response" do
    header "Authorization", "Bearer pipeline-key"
    get "/internal/credentials/openapi.json"
    doc = JSON.parse(last_response.body)
    expect(doc).to be_a_valid_openapi_document
    expect(doc.dig("paths", "/integration_credentials/v1", "post", "tags")).to eq(["Credentials"])

    read(token: "pipeline-key")
    expect(last_response).to match_openapi_response(doc, operation_id: "integration_credentials_v1")
    read(token: "ops-key")
    expect(last_response).to match_openapi_response(doc, operation_id: "integration_credentials_v1") # the 403
  end

  it "serves the same document as YAML behind the same gate" do
    get "/internal/credentials/openapi.yaml"
    expect(last_response.status).to eq(401)
    header "Authorization", "Bearer ops-key"
    get "/internal/credentials/openapi.yaml"
    expect(last_response.headers["content-type"]).to eq("application/yaml")
    expect(YAML.safe_load(last_response.body)["info"]["title"]).to eq("Credentials API")
  end

  it "authenticates and enforces the allowlist on the controller skin too" do
    post "/credentials/read", '{"company_uuid":"c-1"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(401)
    header "Authorization", "Bearer ops-key"
    post "/credentials/read", '{"company_uuid":"c-1"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(403)
    header "Authorization", "Bearer pipeline-key"
    post "/credentials/read", '{"company_uuid":"c-1"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
  end
end
