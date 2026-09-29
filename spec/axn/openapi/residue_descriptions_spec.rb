# frozen_string_literal: true

require "rack/mock"

# Core renders each input_schema residue into its property's `description`. This adapter must carry
# those descriptions to the served document unchanged, and must not add residue prose of its own.
# Equality with core is what keeps the wording identical across every tool adapter.
RSpec.describe "input_schema residue descriptions in the served OpenAPI document" do
  def served_document(tools)
    app = Axn::OpenAPI::App.new(auth: :none, tools:)
    JSON.parse(Rack::MockRequest.new(app).get("/openapi.json").body)
  end

  def request_body_schema(doc, path)
    doc.dig("paths", path, "post", "requestBody", "content", "application/json", "schema")
  end

  # Every `description` in a schema tree, keyed by its path of keys and indices.
  def descriptions(node, path = [], found = {})
    case node
    when Hash
      found[path] = node["description"] if node.key?("description")
      node.each { |key, value| descriptions(value, path + [key], found) }
    when Array
      node.each_with_index { |value, index| descriptions(value, path + [index], found) }
    end
    found
  end

  def wire(value) = JSON.parse(JSON.generate(value))

  let(:body) { request_body_schema(served_document([ResidueTool]), "/residue_tool/v1") }
  let(:core_descriptions) { descriptions(wire(ResidueTool.input_schema)) }

  it "serves every request-body description exactly as core's input_schema renders it" do
    expect(descriptions(body)).to eq(core_descriptions)
  end

  it "carries each residue's prose to its property, top-level and nested" do
    residues = ResidueTool.input_schema_residues
    expect(residues.map(&:path).uniq).to contain_exactly(%i[code], %i[slug], %i[meta count], %i[widget_id])

    residues.each do |residue|
      schema_path = residue.path.flat_map { |segment| ["properties", segment.to_s] }
      description = descriptions(body).fetch(schema_path)
      expect(description.scan(residue.summary).size).to eq(1)
    end
  end

  it "keeps a nullable property's type array (the document is OpenAPI 3.1, no nullable conversion)" do
    expect(body.dig("properties", "slug", "type")).to eq(%w[string null])
  end

  it "leaves a residue-free tool's request body equal to core's input_schema" do
    expect(EchoTool.input_schema_residues).to be_empty
    echo_body = request_body_schema(served_document([EchoTool]), "/echo_tool/v1")
    expect(echo_body).to eq(wire(EchoTool.input_schema))
  end

  it "is a valid OpenAPI 3.1 document" do
    expect(Axn::OpenAPI.spec(tools: [ResidueTool])).to be_a_valid_openapi_document
  end
end
