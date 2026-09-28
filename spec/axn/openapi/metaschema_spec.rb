# frozen_string_literal: true

RSpec.describe "generated documents against the OpenAPI 3.1 metaschema" do
  it "accepts the document for the fixture tools" do
    expect(Axn::OpenAPI.spec(tools: [EchoTool, RefuseTool, ContextEchoTool, CalcV1Tool, CalcV2Tool])).to be_a_valid_openapi_document
  end

  it "rejects a broken document (guards against a matcher that accepts anything)" do
    expect({ "openapi" => "3.1.0", "paths" => { "x" => {} } }).not_to be_a_valid_openapi_document
  end
end
