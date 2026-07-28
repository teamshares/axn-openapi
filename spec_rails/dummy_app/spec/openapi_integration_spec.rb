# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "axn-openapi inside Rails" do
  include Rack::Test::Methods

  def app = Rails.application

  it "serves a mounted tool over a real request" do
    post "/api/echo_tool/v1", '{"message":"hi"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("echoed" => "hi")
  end

  it "serves the OpenAPI spec via the mount" do
    get "/api/openapi.json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["paths"]).to have_key("/echo_tool/v1")
  end

  it "dispatches via the controller mixin (render_axn), mapping fail! to 422" do
    post "/loans/approve", '{"amount":5}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(422)
    expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Amount too large")
  end

  it "flows request-derived ambient_context from the HTTP request into the tool" do
    post "/loans/whoami", "{}", "CONTENT_TYPE" => "application/json", "HTTP_X_ACTOR" => "alice"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("actor" => "alice")
  end

  it "serves two coexisting versions of a tool at distinct paths with distinct contracts" do
    post "/api/greeter/v1", '{"subject":"ada"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("greeting" => "hi ada")

    post "/api/greeter/v2", '{"subject":"ada"}', "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("greeting" => "Hello, ada!")
  end

  it "lists both versions in the served spec" do
    get "/api/openapi.json"
    expect(JSON.parse(last_response.body)["paths"].keys).to include("/greeter/v1", "/greeter/v2")
  end

  it "404s a nonexistent version with a pointer to the latest" do
    post "/api/greeter/v9", "{}", "CONTENT_TYPE" => "application/json"
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body)["error"]["message"]).to include("/greeter/v2")
  end

  it "publishes the mount base (/api) as the served spec's servers entry" do
    get "/api/openapi.json"
    expect(JSON.parse(last_response.body)["servers"]).to eq([{ "url" => "/api" }])
  end
end
