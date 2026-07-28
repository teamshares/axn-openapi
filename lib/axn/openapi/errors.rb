# frozen_string_literal: true

module Axn
  module OpenAPI
    # Raised by the strict serializer when an exposed value or Hash key has no meaningful JSON
    # representation: it (or a key) serializes only via the inherited Object/Kernel #to_s (e.g.
    # "#<User:0x…>"), two keys collapse to the same stringified property, or a container is
    # self-referential. The Dispatcher maps it to a generic 500 with a precise, logged #reason —
    # shipping such a body to an API consumer is a contract bug in the OutboundValidationError family.
    # (Note: pure ENCODE failures — non-finite numbers, invalid UTF-8 — are NOT this error; they pass
    # the strict walk and are caught later by Dispatcher.ensure_encodable as a generic 500.)
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
