# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # The spine. Runs an Axn through the sanctioned Axn::Tools::Invoker and maps the returned
    # Axn::Result to a Dispatch (status + body) per the approved status scheme. This is the ONLY
    # place error/status semantics live; all three skins delegate here.
    module Dispatcher
      module_function

      GENERIC_500 = { "error" => { "message" => "Internal Server Error" } }.freeze
      MALFORMED_400 = { "error" => { "message" => "Malformed JSON request body" } }.freeze

      # Parse a raw request body into params, shared by both skins (mount Router and controller mixin)
      # so they can't diverge on what counts as malformed. Blank body -> `{}` (a bodyless call). A valid
      # JSON object -> its Hash. Malformed JSON, or a valid-but-non-object JSON value (array/number/
      # string), -> `nil` — the caller renders `malformed_body_dispatch` (400). `nil` is unambiguous:
      # every accepted body parses to a Hash.
      def parse_body(raw_body)
        # JSON must be UTF-8 (RFC 8259). A body with invalid UTF-8 bytes is malformed — reject it
        # here (→ 400) so a bad key like `{"\xFF":1}` can't blow up later in key symbolization, which
        # happens before a Dispatch exists and so escapes the render-boundary encode gate. Check on a
        # UTF-8 view of the bytes (Rack input arrives ASCII-8BIT, where every byte is "valid").
        body = raw_body.to_s.dup.force_encoding(Encoding::UTF_8)
        return nil unless body.valid_encoding?
        return {} if body.strip.empty?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def malformed_body_dispatch
        Dispatch.new(400, MALFORMED_400)
      end

      def call(axn_class:, params:, ambient_context: {})
        invoker = Axn::Tools::Invoker.new(
          user_facing_input_errors: true,
          reject_undeclared_inputs: Axn::OpenAPI.config.reject_undeclared_inputs,
        )
        # Top-level keys must be Symbols for the Invoker's `**` splat; nested Hashes stay as-is
        # (axn reads nested subfields by key from a Hash source regardless of key type).
        result = invoker.call(axn_class, symbolize_top(params), ambient_context:)

        if result.ok?
          success(axn_class, result)                                        # 200
        elsif Axn::Tools::Invoker.input_invalid?(result)
          validation_error(result)                                          # 400
        elsif result.outcome.failure?
          failure(result)                                                   # 422
        else
          Dispatch.new(500, GENERIC_500)                                    # already paged on_exception
        end
      end

      # The JSON-encodability gate applied at the RENDER BOUNDARY (each skin calls this on the final
      # dispatch before rendering). Covers EVERY body a skin can render — a tool result's exposures or
      # `fail!`/validation message, a router 404 that echoes request-derived text, or a generated spec
      # doc — all of which may carry attacker- or upstream-influenced strings (e.g. invalid UTF-8). An
      # unencodable body maps to the documented generic 500 instead of raising mid-render and escaping
      # the Rack app / controller. `SystemStackError` is named explicitly (a cyclic body recurses past
      # StandardError). The 500 body is trivially encodable, so an already-500 dispatch passes through.
      def ensure_encodable(dispatch)
        JSON.generate(dispatch.body)
        dispatch
      rescue StandardError, SystemStackError => e
        Axn.config.logger.error { "[axn-openapi] response body not JSON-encodable (was #{dispatch.status}): #{e.class}: #{e.message}" }
        Dispatch.new(500, GENERIC_500)
      end

      def success(axn_class, result)
        body = Serializer.serialize(result, axn_class.external_field_configs,
                                    strict: Axn::OpenAPI.config.strict_serialization)
        Dispatch.new(200, body)
      rescue StandardError, SystemStackError => e
        # Serialization itself failed (before we could build a body): an unrepresentable value
        # (UnserializableExposureError), an exception from a value's own as_json/to_h projection, or a
        # self-referential container recursing to SystemStackError (not a StandardError, so named).
        # A server-side problem, not a 200 → generic 500. (Pure encode failures are caught centrally
        # by ensure_encodable; this rescue is for exceptions raised DURING serialize_exposed.)
        Axn.config.logger.error { "[axn-openapi] failed to serialize successful result: #{e.class}: #{e.message}" }
        Dispatch.new(500, GENERIC_500)
      end

      def validation_error(result)
        error = { "message" => result.error }
        error["field_errors"] = result.exception.field_errors if result.exception.respond_to?(:field_errors)
        Dispatch.new(400, { "error" => error })
      end

      def failure(result)
        Dispatch.new(422, { "error" => { "message" => result.error } })
      end

      def symbolize_top(params)
        params.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end
    end
  end
end
