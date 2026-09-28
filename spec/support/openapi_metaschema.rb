# frozen_string_literal: true

require "json"
require "json_schemer"

# Asserts a generated document is a valid OpenAPI 3.1 document (json_schemer's bundled metaschema).
# The document is round-tripped through JSON first so Symbol keys core's reflection emits are
# validated exactly as a client would receive them.
RSpec::Matchers.define :be_a_valid_openapi_document do
  match do |doc|
    @errors = JSONSchemer.openapi(JSON.parse(JSON.generate(doc))).validate.map { |e| e["error"] }
    @errors.empty?
  end

  failure_message { "expected a valid OpenAPI 3.1 document, got:\n  #{@errors.first(10).join("\n  ")}" }
end
