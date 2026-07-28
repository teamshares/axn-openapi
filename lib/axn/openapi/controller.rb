# frozen_string_literal: true

module Axn
  module OpenAPI
    # Controller skin, for consumers who want their existing auth/filters/middleware stack. The
    # controller owns routing (a Rails route → an action → `render_axn(SomeAxn)`) and supplies the
    # trusted ambient_context; this delegates body parsing + the run + status/envelope mapping to the
    # shared Dispatcher and renders the result — so it behaves identically to the mount Router,
    # including rejecting a malformed body with a 400 (rather than silently dispatching `{}`).
    module Controller
      # `ambient_context:` typically carries request-derived trusted data (current_user, request id).
      def render_axn(axn_class, ambient_context: {})
        params = Dispatcher.parse_body(request.raw_post)
        dispatch = if params.nil?
                     Dispatcher.malformed_body_dispatch
                   else
                     Dispatcher.call(axn_class:, params:, ambient_context:)
                   end
        # Render boundary: guarantee the body is JSON-encodable before the renderer touches it, so an
        # unencodable value maps to the documented generic 500 rather than raising in `render json:`.
        dispatch = Dispatcher.ensure_encodable(dispatch)
        # No `dispatch.headers` to forward here: every dispatch this path can produce (Dispatcher.call,
        # malformed_body_dispatch) carries none — the only headered response is the Router's 405+Allow,
        # which is mount-only. If a headered dispatch ever reaches here, forward it via response.headers.
        render json: dispatch.body, status: dispatch.status
      end
    end
  end
end
