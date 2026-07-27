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

      def call(axn_class:, params:, ambient_context: {})
        invoker = Axn::Tools::Invoker.new(
          user_facing_input_errors: true,
          reject_undeclared_inputs: Axn::OpenAPI.config.reject_undeclared_inputs,
        )
        # Top-level keys must be Symbols for the Invoker's `**` splat; nested Hashes stay as-is
        # (axn reads nested subfields by key from a Hash source regardless of key type).
        result = invoker.call(axn_class, symbolize_top(params), ambient_context:)

        return success(axn_class, result) if result.ok?
        return validation_error(result) if Axn::Tools::Invoker.input_invalid?(result)   # 400
        return failure(result) if result.outcome.failure?                               # 422

        Dispatch.new(500, GENERIC_500) # already paged on_exception
      end

      def success(axn_class, result)
        body = Serializer.serialize(result, axn_class.external_field_configs,
                                    strict: Axn::OpenAPI.config.strict_serialization)
        # Validate JSON-encodability HERE (the skins re-encode when rendering) so an unencodable
        # success body maps to the documented generic 500 instead of raising from the skin's renderer
        # and escaping as the host framework's error. This is the authoritative encodability gate —
        # it catches what the strict serializer can't/doesn't: a String with invalid UTF-8, and a
        # non-finite number when strict serialization is disabled. Encoding twice on the success path
        # buys one transport-agnostic 500 decision. (The strict serializer still runs first, giving a
        # precise field-level message for garbage `to_s` projections that ARE valid JSON.)
        JSON.generate(body)
        Dispatch.new(200, body)
      rescue StandardError => e
        # A successful Axn whose result can't be serialized/encoded is a server-side problem, not a
        # 200: an unrepresentable value (UnserializableExposureError), a JSON encode failure
        # (JSON::GeneratorError), OR an arbitrary exception raised by a value's own as_json/to_h
        # projection during serialize_exposed. This is the render boundary — none of these may escape
        # the Rack app / controller renderer, so all map to the documented generic 500 (logged for the
        # operator, nothing leaked to the caller). Scoped tight: the only code above that can raise is
        # serialization + JSON.generate.
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
