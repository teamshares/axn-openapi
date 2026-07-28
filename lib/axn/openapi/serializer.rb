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
      def assert_serializable!(value, path, ancestors = [])
        return if SAFE_LEAVES.any? { |k| value.is_a?(k) }

        if value.is_a?(Hash) || value.is_a?(Array)
          return within_container(value, path, ancestors) do
            if value.is_a?(Hash)
              validate_hash!(value, path, ancestors)
            else
              value.each_with_index { |v, i| assert_serializable!(v, "#{path}[#{i}]", ancestors) }
            end
          end
        end

        # serialize_value follows as_json (own) or to_h and then RECURSES into the returned
        # structure (values.rb) — so the guard must recurse too, or a nested opaque leaf inside a
        # custom to_h/as_json result would render via default to_s unchecked. Same order as
        # serialize_value: as_json first, then to_h. This re-invokes as_json/to_h (serialize_exposed
        # calls them again) — an accepted cost: strict mode trades a second pure-projection call for
        # catching un-serializable nested values.
        return assert_serializable!(value.as_json, path, ancestors) if Axn::Reflection::Values.follow_as_json?(value)
        return assert_serializable!(value.to_h, path, ancestors) if value.respond_to?(:to_h)
        return unless DEFAULT_TO_S_OWNERS.include?(value.method(:to_s).owner)

        raise UnserializableExposureError.new(path, value)
      end

      # Guards one container against self-reference: a self-referential Array/Hash would recurse
      # forever to a SystemStackError, which — being outside StandardError — the dispatcher can't
      # cleanly map to a 500, so it'd escape the Rack app. Reject it as a serialization failure
      # instead. Tracks the ANCESTOR CHAIN (push before descending, pop after) rather than every
      # container ever seen, so a shared-but-acyclic reference (a diamond) is NOT a false positive.
      # Identity comparison (`equal?`) — two value-equal containers aren't the same object.
      def within_container(container, path, ancestors)
        if ancestors.any? { |a| a.equal?(container) }
          raise UnserializableExposureError.new(path, container,
                                                reason: "it is self-referential (a #{container.class} cycle), which has no JSON representation")
        end

        ancestors.push(container)
        begin
          yield
        ensure
          ancestors.pop
        end
      end

      # serialize_value renders a Hash's KEYS via `transform_keys(&:to_s)` (never the as_json/to_h
      # value chain), so a key whose only `to_s` is the inherited Object/Kernel default stringifies
      # to garbage like "#<User:0x…>" exactly as a value would — strict mode must reject it too.
      # Values still flow through the full chain via assert_serializable!.
      def validate_hash!(hash, path, ancestors)
        hash.each do |key, value|
          if DEFAULT_TO_S_OWNERS.include?(key.method(:to_s).owner)
            raise UnserializableExposureError.new(
              "#{path} (hash key #{key.inspect})", key,
              reason: "a Hash key serializes via #to_s and this one has only the default Object#to_s " \
                      "(it would stringify to garbage like \"#<…>\")"
            )
          end
          assert_serializable!(value, "#{path}.#{key}", ancestors)
        end
      end
    end
  end
end
