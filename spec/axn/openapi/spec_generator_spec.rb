# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::SpecGenerator do
  subject(:doc) { described_class.new(tools: [EchoTool, RefuseTool]).generate }

  it "emits an OpenAPI 3.1 document with an info block" do
    expect(doc["openapi"]).to eq("3.1.0")
    expect(doc["info"]).to include("title" => "Axn API", "version" => "1.0.0")
  end

  it "emits one POST path per tool with operationId and schemas" do
    op = doc.dig("paths", "/echo_tool", "post")
    expect(op["operationId"]).to eq("echo_tool")
    expect(op["summary"]).to eq("Echoes a message back.")
    expect(op.dig("requestBody", "content", "application/json", "schema")).to eq(EchoTool.input_schema)
    expect(op.dig("responses", "200", "content", "application/json", "schema")).to eq(EchoTool.output_schema)
  end

  it "references the shared Error component for failure responses" do
    op = doc.dig("paths", "/echo_tool", "post")
    %w[400 422 500].each do |code|
      expect(op.dig("responses", code, "content", "application/json", "schema"))
        .to eq("$ref" => "#/components/schemas/Error")
    end
    expect(doc.dig("components", "schemas", "Error", "type")).to eq("object")
  end

  it "emits semantic hints as a vendor extension" do
    op = doc.dig("paths", "/echo_tool", "post")
    expect(op["x-axn-semantic-hints"]).to eq(["read_only"])
  end

  it "honors a path_prefix" do
    d = described_class.new(tools: [EchoTool], path_prefix: "/axns").generate
    expect(d["paths"]).to have_key("/axns/echo_tool")
  end
end
