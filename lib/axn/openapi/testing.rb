# frozen_string_literal: true

require "json"
require "axn/openapi"

module Axn
  module OpenAPI
    # Contract checks for a consumer's test suite: is a mount's document valid OpenAPI 3.1 (including
    # its declared examples), and does a response match what the document promises? Opt-in —
    # `require "axn/openapi/testing"` (or `axn/openapi/testing/rspec` for matchers) — and backed by
    # json_schemer, which the consumer adds to its test group; it is not a runtime dependency.
    #
    # Documents and bodies are round-tripped through JSON first, so they're checked exactly as a
    # client receives them (String keys, not the Symbol keys core's reflection emits).
    module Testing
      class ContractViolation < Axn::OpenAPI::Error; end

      HTTP_METHODS = %w[get put post delete options head patch trace].freeze

      module_function

      # Metaschema violations, then — for a document that passes — each declared request/response
      # example checked against its own schema. Empty when the document is sound.
      def document_errors(doc)
        doc = json_roundtrip(doc)
        openapi = json_schemer.openapi(doc)
        errors = openapi.validate.map { |error| error["error"] }
        return errors unless errors.empty?

        each_operation(doc) do |method, path, operation|
          label = "#{method.upcase} #{path}"
          example_errors(openapi, operation.dig("requestBody", "content"), pointer("paths", path, method, "requestBody"),
                         "#{label} request example", errors)
          (operation["responses"] || {}).each do |status, response|
            example_errors(openapi, response["content"], pointer("paths", path, method, "responses", status),
                           "#{label} #{status} response example", errors)
          end
        end
        errors
      end

      # Raises ContractViolation listing the errors; returns the document when it's sound.
      def validate_document!(doc)
        errors = document_errors(doc)
        raise ContractViolation, "invalid OpenAPI document:\n  #{errors.first(20).join("\n  ")}" unless errors.empty?

        doc
      end

      # Does `body` (a Hash, or a JSON String) match the `status` response `operation_id` documents?
      def response_errors(doc, operation_id:, status:, body:)
        doc = json_roundtrip(doc)
        found = nil
        each_operation(doc) { |method, path, operation| found ||= [method, path, operation] if operation["operationId"] == operation_id }
        return ["no operation #{operation_id.inspect} in the document"] unless found

        method, path, operation = found
        status = status.to_s
        response = (operation["responses"] || {})[status]
        return ["operation #{operation_id.inspect} documents no #{status} response"] unless response
        unless response.dig("content", "application/json", "schema")
          return ["operation #{operation_id.inspect} documents no application/json body for #{status}"]
        end

        schema = json_schemer.openapi(doc).ref(pointer("paths", path, method, "responses", status, "content", "application/json", "schema"))
        body = body.is_a?(String) ? JSON.parse(body) : json_roundtrip(body)
        schema.validate(body).map { |error| error["error"] }
      rescue JSON::ParserError => e
        ["response body is not JSON: #{e.message}"]
      end

      # Raises ContractViolation listing the errors; returns the body when it matches.
      def validate_response!(doc, operation_id:, status:, body:)
        errors = response_errors(doc, operation_id:, status:, body:)
        raise ContractViolation, "#{operation_id} #{status} response doesn't match the document:\n  #{errors.join("\n  ")}" unless errors.empty?

        body
      end

      def json_schemer
        require "json_schemer"
        JSONSchemer
      rescue LoadError
        raise Axn::OpenAPI::Error, 'Axn::OpenAPI::Testing needs json_schemer: add `gem "json_schemer"` to your test group'
      end

      def each_operation(doc)
        (doc["paths"] || {}).each do |path, item|
          item.each { |method, operation| yield method, path, operation if HTTP_METHODS.include?(method) }
        end
      end

      def example_errors(openapi, content, base, label, errors)
        media = (content || {})["application/json"]
        return unless media && media["schema"]

        schema = openapi.ref("#{base}/content/application~1json/schema")
        (media["examples"] || {}).each do |name, example|
          next unless example.is_a?(Hash) && example.key?("value")

          schema.validate(example["value"]).each { |error| errors << "#{label} #{name}: #{error['error']}" }
        end
      end

      # A JSON Pointer fragment, escaping each segment (RFC 6901: `~` → `~0`, `/` → `~1`).
      def pointer(*segments) = "#/#{segments.map { |s| s.to_s.gsub('~', '~0').gsub('/', '~1') }.join('/')}"

      def json_roundtrip(value) = JSON.parse(JSON.generate(value))
    end
  end
end
