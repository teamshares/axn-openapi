# frozen_string_literal: true

module Axn
  module OpenAPI
    # Raised (in strict mode) when an exposed value has no meaningful JSON projection — no own
    # as_json, no to_h, and only the inherited Object/Kernel #to_s. The Dispatcher maps it to 500:
    # shipping "#<User:0x…>" to an API consumer is a contract bug in the same family as an
    # OutboundValidationError. #field_path names the offending exposure for the dev-facing message.
    class UnserializableExposureError < Error
      attr_reader :field_path

      def initialize(field_path, value)
        @field_path = field_path
        super(
          "Exposed value at `#{field_path}` (#{value.class}) has no JSON representation — it serializes " \
          "only via the default Object#to_s. Declare it `type: String` and format it, or give the value " \
          "an `as_json`/`to_h`. (Disable with Axn::OpenAPI.config.strict_serialization = false.)"
        )
      end
    end
  end
end
