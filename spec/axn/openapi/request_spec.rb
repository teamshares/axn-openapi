# frozen_string_literal: true

require "pp"
require "rack/mock"

RSpec.describe Axn::OpenAPI::Request do
  def from_env(**env) = described_class.from_rack(Rack::MockRequest.env_for("/tool/v1", method: "POST", input: "{}", **env))

  it "collects HTTP_* headers and the content headers, looked up case-insensitively" do
    request = from_env("HTTP_AUTHORIZATION" => "Bearer abc", "HTTP_X_API_KEY" => "k", "CONTENT_TYPE" => "application/json")
    expect(request.header("Authorization")).to eq("Bearer abc")
    expect(request.header("authorization")).to eq("Bearer abc")
    expect(request.header("X-Api-Key")).to eq("k")
    expect(request.header("Content-Type")).to eq("application/json")
    expect(request.header("X-Missing")).to be_nil
  end

  it "defaults to no headers when built directly" do
    request = described_class.new(http_method: "POST", path: "/x", raw_body: "", script_name: "")
    expect(request.header("Authorization")).to be_nil
  end

  it "never renders headers or the body through inspect or pp" do
    request = from_env("HTTP_AUTHORIZATION" => "Bearer super-secret-token", input: '{"password":"hunter2"}')
    [request.inspect, request.pretty_inspect].each do |rendered|
      expect(rendered).not_to include("super-secret-token")
      expect(rendered).not_to include("hunter2")
      expect(rendered).to include("POST", "/tool/v1")
    end
  end
end
