# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::SpecGenerator do
  subject(:doc) { described_class.new(tools: [EchoTool, CalcV1Tool, CalcV2Tool]).generate }

  it "emits an OpenAPI 3.1 document with an info block" do
    expect(doc["openapi"]).to eq("3.1.0")
    expect(doc["info"]).to include("title" => "Axn API", "version" => "1.0.0")
  end

  it "emits one versioned POST path per tool version" do
    expect(doc["paths"].keys).to include("/echo_tool/v1", "/calc/v1", "/calc/v2")
    expect(doc["paths"]).not_to have_key("/echo_tool") # no bare path
  end

  it "gives each version a doc-unique operationId and its own schemas" do
    v1 = doc.dig("paths", "/calc/v1", "post")
    v2 = doc.dig("paths", "/calc/v2", "post")
    expect(v1["operationId"]).to eq("calc_v1")
    expect(v2["operationId"]).to eq("calc_v2")
    expect(v1.dig("responses", "200", "content", "application/json", "schema")).to eq(CalcV1Tool.output_schema)
    expect(v2.dig("responses", "200", "content", "application/json", "schema")).to eq(CalcV2Tool.output_schema)
  end

  it "still references the shared Error component for failure responses" do
    op = doc.dig("paths", "/echo_tool/v1", "post")
    %w[400 422 500].each do |code|
      expect(op.dig("responses", code, "content", "application/json", "schema")).to eq("$ref" => "#/components/schemas/Error")
    end
  end

  it "honors a path_prefix" do
    d = described_class.new(tools: [EchoTool], path_prefix: "/axns").generate
    expect(d["paths"]).to have_key("/axns/echo_tool/v1")
  end

  it "emits a tool's semantic hints as a plural vendor extension" do
    op = doc.dig("paths", "/echo_tool/v1", "post")
    expect(op["x-axn-semantic-hints"]).to eq(["read_only"])
  end

  it "omits the vendor extension for a tool with no semantic hints" do
    op = doc.dig("paths", "/calc/v1", "post")
    expect(op).not_to have_key("x-axn-semantic-hints")
  end

  it "marks requestBody required when the tool has a required input" do
    # EchoTool: `expects :message, type: String` (required).
    required = doc.dig("paths", "/echo_tool/v1", "post", "requestBody", "required")
    expect(required).to be(true)
  end

  it "marks requestBody optional for an ambient-context-only tool (empty input schema)" do
    d = described_class.new(tools: [ContextEchoTool]).generate
    body = d.dig("paths", "/context_echo_tool/v1", "post", "requestBody")
    expect(body["required"]).to be(false)
    expect(body.dig("content", "application/json", "schema")).to eq(ContextEchoTool.input_schema)
  end
end
