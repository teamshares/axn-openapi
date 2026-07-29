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
          # Per-tool resolution, not a bare config read — SpecGenerator resolves the same way, so the
          # published `additionalProperties` and this runtime check can't disagree for a tool that
          # overrode it via `configure(:openapi)`.
          reject_undeclared_inputs: Axn::OpenAPI.resolve_override_for(axn_class, :reject_undeclared_inputs),
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
      # the Rack app / controller. The 500 body is trivially encodable, so an already-500 dispatch
      # passes through.
      #
      # Still required even though core's serializer now guarantees no *value* JSON.generate refuses
      # (it rejects non-finite numbers, non-UTF-8 bytes, cycles, and collapsed property names itself),
      # for two reasons. That guarantee is about values, not about encoder OPTIONS: a structure nested
      # deeper than JSON's max_nesting still raises JSON::NestingError here. And it covers only bodies
      # core built — a router 404 or a generated spec document never passes through serialize_exposed
      # at all, and those are exactly the request-derived bodies most likely to carry bad bytes.
      #
      # `SystemStackError` is named explicitly: deep nesting is the failure mode this gate now exists
      # for, and a body deep enough to exhaust the stack rather than trip max_nesting raises outside
      # StandardError.
      def ensure_encodable(dispatch)
        JSON.generate(dispatch.body)
        dispatch
      rescue StandardError, SystemStackError => e
        Axn.config.logger.error { "[axn-openapi] response body not JSON-encodable (was #{dispatch.status}): #{e.class}: #{e.message}" }
        Dispatch.new(500, GENERIC_500)
      end

      def success(axn_class, result)
        # The one place the adapter's config vocabulary is translated to core's keyword — Serializer
        # sits adjacent to core's call and speaks core's name for it.
        #
        # Resolved via resolve_override_for rather than read off `config`, so a per-tool
        # `configure(:openapi)` override wins over the gem-wide default (and so a same-named class
        # method on the action can't silently shadow the override store).
        reject_opaque = Axn::OpenAPI.resolve_override_for(axn_class, :reject_opaque_exposed_values)
        body = Serializer.serialize(result, axn_class.external_field_configs, reject_opaque:)
        Dispatch.new(200, body)
      rescue StandardError, SystemStackError => e
        # Serialization itself failed (before we could build a body): a value with no honest JSON
        # representation (core's Axn::Reflection::UnserializableValue, which names the offending
        # field path), or an exception raised by a value's own as_json/to_h projection. A server-side
        # problem, not a 200 → generic 500.
        #
        # SystemStackError is still named even though core now cycle-guards its own walk: `result` is
        # arbitrary user code, and an as_json/to_h projection is free to recurse on its own. It is not
        # a StandardError, so it would otherwise escape the Rack app / controller.
        #
        # The config pointer lives HERE rather than in the exception message: core raises the same error
        # for adapters that have no such setting, so it must not name this gem's config knob. An
        # operator reads this line, which is the one place that knows both the error and the knob.
        #
        # It names the TOOL and BOTH levels, never just the gem-wide setter. The value is resolved
        # per-tool, so a `configure(:openapi)` override on this action beats `config` — pointing an
        # operator at the gem-wide setting would be a dead end whenever the override is what's in
        # effect (worst case: the gem-wide value is already `false`, so following the advice changes
        # nothing and the endpoint keeps 500ing). Core exposes no way to ask which level supplied a
        # resolved value — `resolve_override_for` collapses override and fallback — so the honest hint
        # describes both and lets the operator look at the one action it names.
        hint = if reject_opaque
                 " (if this is an opaque-value rejection: reject_opaque_exposed_values resolved true for " \
                   "#{axn_class} — unset it on the action via `configure(:openapi)`, or gem-wide via " \
                   "`Axn::OpenAPI.config.reject_opaque_exposed_values = false`, whichever is set)"
               else
                 ""
               end
        Axn.config.logger.error { "[axn-openapi] failed to serialize successful result: #{e.class}: #{e.message}#{hint}" }
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
