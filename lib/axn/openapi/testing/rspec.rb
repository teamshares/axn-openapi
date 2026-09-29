# frozen_string_literal: true

require "axn/openapi/testing"

# RSpec matchers over Axn::OpenAPI::Testing:
#
#   expect(Axn::OpenAPI.spec(mount: :credentials)).to be_a_valid_openapi_document
#   expect(response).to match_openapi_response(doc, operation_id: "list_integrations_v1")
#
# `match_openapi_response` takes a response object (anything with #status and #body — Rack's
# MockResponse, a Rails request-spec `response`), whose status it reads, or a bare body (a Hash or
# JSON String) with an explicit `status:`.
RSpec::Matchers.define :be_a_valid_openapi_document do
  match do |doc|
    @errors = Axn::OpenAPI::Testing.document_errors(doc)
    @errors.empty?
  end

  failure_message { "expected a valid OpenAPI 3.1 document, got:\n  #{@errors.first(10).join("\n  ")}" }
end

RSpec::Matchers.define :match_openapi_response do |doc, operation_id:, status: nil|
  match do |actual|
    response = actual.respond_to?(:status) && actual.respond_to?(:body)
    @status = status || (response ? actual.status : raise(ArgumentError, "match_openapi_response needs status: for a bare body"))
    @errors = Axn::OpenAPI::Testing.response_errors(doc, operation_id:, status: @status, body: response ? actual.body : actual)
    @errors.empty?
  end

  failure_message { "expected a #{@status} response matching #{operation_id} in the document, got:\n  #{@errors.join("\n  ")}" }
  failure_message_when_negated { "expected the #{@status} response not to match #{operation_id} in the document" }
end
