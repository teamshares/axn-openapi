# frozen_string_literal: true

module Axn
  module OpenAPI
    # Success-body serialization — a thin pass-through to axn core's canonical, schema-aligned
    # Axn::Reflection::Values.serialize_exposed (the same serializer axn-mcp uses), so the body
    # matches output_schema by construction.
    #
    # Core owns every "this value has no honest JSON representation" rejection, raising
    # Axn::Reflection::UnserializableValue (an ArgumentError) that names the path to the offending
    # value. Two tiers:
    #
    #   * Unconditional — what would render is not JSON at all: a self-referential container, two
    #     Hash keys (or two exposed field names) that stringify to one property and would silently
    #     drop a value, a non-finite Float, or a String whose bytes have no UTF-8 rendering.
    #   * `reject_opaque:` — what would render is honest but not presentable: a value or Hash key
    #     whose only `to_s` is the inherited Object#to_s, or a value whose only `as_json` is the
    #     generic one ActiveSupport adds (an instance-variable dump). Shipping `"#<User:0x…>"` or a
    #     leaked ivar dump in a published HTTP contract is a bug, so this adapter defaults it on;
    #     axn-mcp leaves it off (its output goes to an LLM, not a published contract).
    #
    # This deliberately does NOT pre-walk the value graph to check any of that. It used to, which
    # meant mirroring core's branch decisions (leaf types, `as_json`-before-`to_h` ordering, key
    # stringification) from the outside — a prediction that had already drifted from the renderer it
    # predicted. Only the code doing the rendering can say what the rendering would be.
    module Serializer
      module_function

      def serialize(result, field_configs, reject_opaque:)
        Axn::Reflection::Values.serialize_exposed(result, field_configs, reject_opaque:)
      end
    end
  end
end
