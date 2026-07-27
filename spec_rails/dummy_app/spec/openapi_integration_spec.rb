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
    expect(JSON.parse(last_response.body)["paths"]).to have_key("/echo_tool")
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
end
