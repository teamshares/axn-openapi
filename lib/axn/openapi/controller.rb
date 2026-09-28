# frozen_string_literal: true

module Axn
  module OpenAPI
    # Controller skin, for consumers who want their existing auth/filters/middleware stack. The
    # controller owns routing (a Rails route → an action → `render_axn(SomeAxn)`) and authentication,
    # and supplies the trusted ambient_context; this delegates body parsing + the run + status/envelope
    # mapping to the shared Dispatcher and renders the result — so it behaves identically to the mount
    # Router, including rejecting a malformed body with a 400 (rather than silently dispatching `{}`).
    module Controller
      UNSET = Object.new.freeze
      private_constant :UNSET

      # `ambient_context:` typically carries request-derived trusted data (current_user, request id).
      #
      # `principal:` is who the controller's own authentication identified the caller as. It is
      # checked against the tool's `allowed_callers` exactly as a mount checks it (403 when refused).
      # A tool that declares `allowed_callers` REQUIRES it: dispatching such a tool without one would
      # silently ignore its declared allowlist on this path, so that raises instead.
      #
      # `mount:` must name the mount a tool is bound to (`tool openapi: { mount: ... }`), and only
      # that mount: a mount-bound tool is meant to be reachable solely behind that mount's auth, so
      # serving it from a controller is an explicit, visible opt-in rather than something any
      # controller can do by naming the class.
      def render_axn(axn_class, ambient_context: {}, principal: UNSET, mount: nil)
        _axn_openapi_check_mount!(axn_class, mount)
        dispatch = Axn::Extensions::InvokedVia.with(:openapi) { _axn_openapi_dispatch(axn_class, ambient_context, principal) }
        # Render boundary: guarantee the body is JSON-encodable before the renderer touches it, so an
        # unencodable value maps to the documented generic 500 rather than raising in `render json:`.
        dispatch = Dispatcher.ensure_encodable(dispatch)
        # No `dispatch.headers` to forward here: every dispatch this path can produce (Dispatcher.call,
        # malformed_body_dispatch, the 403) carries none — the only headered responses are the mount's
        # 401 challenge and 405+Allow. If a headered dispatch ever reaches here, forward it via response.headers.
        render json: dispatch.body, status: dispatch.status
      end

      private

      def _axn_openapi_check_mount!(axn_class, mount)
        declared = Axn::OpenAPI.resolve_override_for(axn_class, :mount)
        return if declared == mount

        raise Axn::OpenAPI::Error,
              if declared
                "#{axn_class} is bound to `tool openapi: { mount: #{declared.inspect} }`; serving it from a controller " \
                  "requires render_axn(..., mount: #{declared.inspect}) — and the same authentication that mount enforces"
              else
                "#{axn_class} is not bound to mount #{mount.inspect}; drop mount: from render_axn"
              end
      end

      def _axn_openapi_dispatch(axn_class, ambient_context, principal)
        if principal.equal?(UNSET)
          if Axn::OpenAPI.resolve_override_for(axn_class, :allowed_callers)
            raise Axn::OpenAPI::Error,
                  "#{axn_class} declares allowed_callers; pass render_axn(..., principal:) with the caller your " \
                  "controller authenticated, so the allowlist is enforced"
          end
        else
          denied = Gate.authorization_dispatch(principal:, axn_class:, operation_id: RouteTable.operation_id(axn_class))
          return denied if denied
        end

        params = Dispatcher.parse_body(request.raw_post)
        return Dispatcher.malformed_body_dispatch if params.nil?

        Dispatcher.call(axn_class:, params:, ambient_context:)
      end
    end
  end
end
