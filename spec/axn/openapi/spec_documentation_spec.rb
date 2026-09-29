# frozen_string_literal: true

RSpec.describe "documentation settings in the generated document" do
  def doc_for(*tools) = Axn::OpenAPI::SpecGenerator.new(tools:).generate
  def op(doc, path) = doc.dig("paths", path, "post")

  describe "operation_tags" do
    let(:doc) { doc_for(TaggedTool, AlsoTaggedTool, EchoTool) }

    it "emits a tool's operation_tags as the operation's tags" do
      expect(op(doc, "/tagged/v1")["tags"]).to eq(%w[Credentials Integrations])
      expect(op(doc, "/also_tagged/v1")["tags"]).to eq(["Credentials"])
    end

    it "omits tags on an untagged operation" do
      expect(op(doc, "/echo_tool/v1")).not_to have_key("tags")
    end

    it "lists every tag once at the top level, in first-seen order" do
      expect(doc["tags"]).to eq([{ "name" => "Credentials" }, { "name" => "Integrations" }])
    end

    it "hands each document its own tag Strings" do
      op(doc, "/tagged/v1")["tags"][0].replace("Mutated")
      doc["tags"][1]["name"].replace("Mutated")
      fresh = doc_for(TaggedTool)
      expect(op(fresh, "/tagged/v1")["tags"]).to eq(%w[Credentials Integrations])
      expect(fresh["tags"]).to eq([{ "name" => "Credentials" }, { "name" => "Integrations" }])
    end

    it "omits the top-level tags list when nothing is tagged" do
      expect(doc_for(EchoTool)).not_to have_key("tags")
    end

    it "accepts only a non-empty Array of Strings (or nil)" do
      expect { Axn::OpenAPI.config.operation_tags = [] }.to raise_error(ArgumentError, /operation_tags/)
      expect { Axn::OpenAPI.config.operation_tags = "Credentials" }.to raise_error(ArgumentError, /operation_tags/)
      expect { Axn::OpenAPI.config.operation_tags = [:credentials] }.to raise_error(ArgumentError, /operation_tags/)
    end
  end

  describe "deprecated" do
    it "deprecates every version older than the tool's latest in the document" do
      doc = doc_for(CalcV1Tool, CalcV2Tool)
      expect(op(doc, "/calc/v1")["deprecated"]).to be(true)
      expect(op(doc, "/calc/v2")).not_to have_key("deprecated")
    end

    it "judges 'latest' within the document: a lone older version isn't deprecated" do
      expect(op(doc_for(CalcV1Tool), "/calc/v1")).not_to have_key("deprecated")
    end

    it "honors a tool forcing it either way" do
      doc = doc_for(PinnedV1Tool, PinnedV2Tool, RetiredTool)
      expect(op(doc, "/pinned/v1")).not_to have_key("deprecated")
      expect(op(doc, "/retired/v1")["deprecated"]).to be(true)
    end

    it "accepts only true, false or nil" do
      expect { Axn::OpenAPI.config.deprecated = "yes" }.to raise_error(ArgumentError, /deprecated/)
    end
  end

  describe "examples" do
    let(:doc) { doc_for(TaggedTool, EchoTool) }

    it "emits request_example on the request body and response_example on the 200, JSON-shaped" do
      request = op(doc, "/tagged/v1").dig("requestBody", "content", "application/json", "examples")
      response = op(doc, "/tagged/v1").dig("responses", "200", "content", "application/json", "examples")
      expect(request).to eq("default" => { "value" => { "company_uuid" => "c-1", "filters" => { "active" => true } } })
      expect(response).to eq("default" => { "value" => { "integrations" => [{ "name" => "gusto" }] } })
    end

    it "omits examples a tool doesn't declare" do
      expect(op(doc, "/echo_tool/v1").dig("requestBody", "content", "application/json")).not_to have_key("examples")
    end

    it "hands each document its own copy, down to the leaf Strings" do
      value = op(doc, "/tagged/v1").dig("requestBody", "content", "application/json", "examples", "default", "value")
      value["company_uuid"].replace("mutated") # in place, on a String the config also holds
      value["filters"]["active"] = false
      fresh = op(doc_for(TaggedTool), "/tagged/v1").dig("requestBody", "content", "application/json", "examples", "default", "value")
      expect(fresh).to eq("company_uuid" => "c-1", "filters" => { "active" => true })
    end

    it "refuses an example with no JSON rendering at declaration, so serving the document can't raise" do
      expect { Axn::OpenAPI.config.request_example = { n: Float::NAN } }.to raise_error(ArgumentError, /request_example must be JSON-encodable/)
      invalid_utf8 = "\xFF".b.force_encoding("UTF-8")
      expect { Axn::OpenAPI.config.response_example = { s: invalid_utf8 } }
        .to raise_error(ArgumentError, /response_example must be JSON-encodable/)
      cycle = {}
      cycle[:self] = cycle
      expect { Axn::OpenAPI.config.request_example = cycle }.to raise_error(ArgumentError, /request_example must be JSON-encodable/)
    end

    it "accepts only a Hash (or nil)" do
      expect { Axn::OpenAPI.config.request_example = "x" }.to raise_error(ArgumentError, /request_example/)
      expect { Axn::OpenAPI.config.response_example = [1] }.to raise_error(ArgumentError, /response_example/)
    end
  end

  it "keeps the document valid OpenAPI 3.1" do
    expect(doc_for(TaggedTool, AlsoTaggedTool, CalcV1Tool, CalcV2Tool, RetiredTool)).to be_a_valid_openapi_document
  end
end
