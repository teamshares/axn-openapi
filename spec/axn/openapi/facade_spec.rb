# frozen_string_literal: true

require "rack/mock"

RSpec.describe "Axn::OpenAPI facade" do
  it ".tools enumerates registered :openapi tools" do
    expect(Axn::OpenAPI.tools).to include(EchoTool)
  end

  it ".spec generates the document for all registered tools by default" do
    expect(Axn::OpenAPI.spec["paths"]).to have_key("/echo_tool/v1")
  end

  it ".app builds a mountable Rack app end-to-end" do
    res = Rack::MockRequest.new(Axn::OpenAPI.app(tools: [EchoTool]))
                           .post("/echo_tool/v1", input: '{"message":"hi"}')
    expect(JSON.parse(res.body)).to eq("echoed" => "hi")
  end
end
