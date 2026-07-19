# frozen_string_literal: true

require "date"

module Axn
  module OpenAPI
    # Success-body serialization. The actual work is axn core's canonical, schema-aligned
    # Axn::Reflection::Values.serialize_exposed (the same serializer axn-mcp uses), so the body
    # matches output_schema by construction. In strict mode a pre-pass raises on any exposed leaf
    # that serialize_value would render via the default Object#to_s — a garbage projection an HTTP
    # contract must not ship silently.
    module Serializer
      module_function

      # Leaf types serialize_value handles losslessly (see Axn::Reflection::Values.serialize_value).
      SAFE_LEAVES = [NilClass, String, Integer, Float, TrueClass, FalseClass, Symbol, Numeric,
                     Time, DateTime, Date].freeze
      DEFAULT_TO_S_OWNERS = [::Object, ::Kernel].freeze

      def serialize(result, field_configs, strict:)
        field_configs.each { |c| assert_serializable!(result.public_send(c.field), c.field.to_s) } if strict
        Axn::Reflection::Values.serialize_exposed(result, field_configs)
      end

      # Mirrors serialize_value's branch decisions (reusing Values.follow_as_json? so the two can't
      # drift): a value is serializable unless it reaches the `value.to_s` branch (no own as_json,
      # no to_h) AND that to_s is the inherited default.
      def assert_serializable!(value, path)
        return if SAFE_LEAVES.any? { |k| value.is_a?(k) }
        return value.each { |k, v| assert_serializable!(v, "#{path}.#{k}") } if value.is_a?(Hash)
        return value.each_with_index { |v, i| assert_serializable!(v, "#{path}[#{i}]") } if value.is_a?(Array)
        return if Axn::Reflection::Values.follow_as_json?(value) # serialize_value follows as_json
        return if value.respond_to?(:to_h)                       # serialize_value follows to_h
        return unless DEFAULT_TO_S_OWNERS.include?(value.method(:to_s).owner)

        raise UnserializableExposureError.new(path, value)
      end
    end
  end
end
