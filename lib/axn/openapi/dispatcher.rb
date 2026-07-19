# frozen_string_literal: true

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
        Dispatch.new(200, body)
      rescue UnserializableExposureError => e
        Axn.config.logger.error { "[axn-openapi] #{e.message}" }
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
