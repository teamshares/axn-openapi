# frozen_string_literal: true

module Axn
  module OpenAPI
    # Raised (in strict mode) when an exposed value has no JSON representation — either it serializes
    # only via the inherited Object/Kernel #to_s (e.g. "#<User:0x…>"), or it's a non-finite number
    # (NaN/Infinity) that JSON.generate rejects. The Dispatcher maps it to 500: shipping either to an
    # API consumer is a contract bug in the same family as an OutboundValidationError, and catching it
    # here keeps such results on the documented no-leak 500 path instead of raising mid-render.
    # #field_path names the offending exposure; #reason is the specific defect.
    class UnserializableExposureError < Error
      DEFAULT_REASON = "it serializes only via the default Object#to_s — declare it `type: String` " \
                       "and format it, or give the value an `as_json`/`to_h`"

      attr_reader :field_path

      def initialize(field_path, value, reason: DEFAULT_REASON)
        @field_path = field_path
        super(
          "Exposed value at `#{field_path}` (#{value.class}) has no JSON representation — #{reason}. " \
          "(Disable with Axn::OpenAPI.config.strict_serialization = false.)"
        )
      end
    end
  end
end
