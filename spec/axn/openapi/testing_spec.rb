# frozen_string_literal: true

require "axn/openapi/testing"
require "rack/mock"

RSpec.describe Axn::OpenAPI::Testing do
  let(:doc) { Axn::OpenAPI.spec(tools: [EchoTool, RefuseTool, TaggedTool, CalcV1Tool, CalcV2Tool]) }

  describe ".document_errors" do
    it "is empty for a generated document, examples included" do
      expect(described_class.document_errors(doc)).to eq([])
    end

    it "lists metaschema violations" do
      errors = described_class.document_errors({ "openapi" => "3.1.0", "paths" => { "x" => {} } })
      expect(errors).not_to be_empty
    end

    it "catches an example that doesn't satisfy its operation's schema" do
      errors = described_class.document_errors(Axn::OpenAPI.spec(tools: [BadExampleTool]))
      expect(errors).to contain_exactly(a_string_matching(%r{\APOST /bad_example/v1 request example default: value at `/n` is not an integer}))
    end

    it "raises from validate_document!" do
      expect { described_class.validate_document!(Axn::OpenAPI.spec(tools: [BadExampleTool])) }
        .to raise_error(Axn::OpenAPI::Testing::ContractViolation, /bad_example/)
      expect(described_class.validate_document!(doc)).to equal(doc)
    end
  end

  describe ".response_errors" do
    it "accepts a body matching the operation's response schema" do
      expect(described_class.response_errors(doc, operation_id: "echo_tool_v1", status: 200, body: { "echoed" => "hi" })).to eq([])
      expect(described_class.response_errors(doc, operation_id: "refuse_tool_v1", status: 422,
                                                  body: '{"error":{"message":"Amount too large"}}')).to eq([])
    end

    it "catches a body that doesn't match (resolving the shared Error $ref)" do
      expect(described_class.response_errors(doc, operation_id: "echo_tool_v1", status: 200, body: { "echoed" => 1 })).not_to be_empty
      expect(described_class.response_errors(doc, operation_id: "refuse_tool_v1", status: 422, body: { "oops" => true })).not_to be_empty
    end

    it "reports an unknown operation or an undocumented status" do
      expect(described_class.response_errors(doc, operation_id: "nope_v1", status: 200, body: {}))
        .to eq(['no operation "nope_v1" in the document'])
      expect(described_class.response_errors(doc, operation_id: "echo_tool_v1", status: 418, body: {}))
        .to eq(['operation "echo_tool_v1" documents no 418 response'])
    end

    it "raises from validate_response!" do
      expect { described_class.validate_response!(doc, operation_id: "echo_tool_v1", status: 200, body: { "echoed" => 1 }) }
        .to raise_error(Axn::OpenAPI::Testing::ContractViolation, /echo_tool_v1 200/)
    end
  end

  it "explains how to install json_schemer when it's missing" do
    allow(described_class).to receive(:require).with("json_schemer").and_raise(LoadError)
    expect { described_class.document_errors(doc) }.to raise_error(Axn::OpenAPI::Error, /add `gem "json_schemer"`/)
  end

  describe "RSpec matchers" do
    it "matches a served response, taking the status from it" do
      app = Axn::OpenAPI.app(auth: :none, tools: [EchoTool, RefuseTool])
      mock = Rack::MockRequest.new(app)
      served = JSON.parse(mock.get("/openapi.json").body)
      expect(served).to be_a_valid_openapi_document

      expect(mock.post("/echo_tool/v1", input: '{"message":"hi"}')).to match_openapi_response(served, operation_id: "echo_tool_v1")
      expect(mock.post("/refuse_tool/v1", input: '{"amount":1}')).to match_openapi_response(served, operation_id: "refuse_tool_v1")
      expect({ "echoed" => 1 }).not_to match_openapi_response(served, operation_id: "echo_tool_v1", status: 200)
    end
  end
end
