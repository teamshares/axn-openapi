# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # Controller skin, for consumers who want their existing auth/filters/middleware stack. The
    # controller owns routing (a Rails route → an action → `render_axn(SomeAxn)`) and supplies the
    # trusted ambient_context; this delegates the run + status/envelope mapping to the shared
    # Dispatcher and renders the result.
    module Controller
      # `ambient_context:` typically carries request-derived trusted data (current_user, request id).
      def render_axn(axn_class, ambient_context: {})
        params = parse_axn_body
        dispatch = Dispatcher.call(axn_class:, params:, ambient_context:)
        render json: dispatch.body, status: dispatch.status
      end

      private

      def parse_axn_body
        body = request.raw_post.to_s
        return {} if body.strip.empty?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {} # a malformed body dispatches as empty params → surfaces as a 400 InboundValidationError
      end
    end
  end
end
