# frozen_string_literal: true

require "spec_helper"
require "rack/test"

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

  it "survives a route reload: rebuilding each mount from routes.rb replaces its claim" do
    expect { Rails.application.reload_routes! }.not_to raise_error
    read(token: "pipeline-key")
    expect(last_response.status).to eq(200)
  end

  describe "route redraws" do
    after { Rails.application.reload_routes! }

    # A local, not a method: the draw block is instance_exec'd on the route Mapper.
    let(:build) { -> { Axn::OpenAPI.app(auth: CREDENTIALS_AUTH, mount: :credentials, tools: [IntegrationCredentials]) } }

    it "releases a cleared route set's claims, so an edit that shifts the mount's line still reloads" do
      build = self.build
      Rails.application.routes.draw { mount build.call => "/internal/credentials" }
      expect do
        Rails.application.routes.draw do
          get "/added_above", to: "credentials#read"
          mount build.call => "/internal/credentials"
        end
      end.not_to raise_error
    end

    it "still refuses one mount built twice within a single draw, even from one line" do
      build = self.build
      expect do
        Rails.application.routes.draw do
          %w[/a /b].each { |at| mount build.call => at }
        end
      end.to raise_error(Axn::OpenAPI::Error, /mount :credentials is already built/i)
    end
  end
end
