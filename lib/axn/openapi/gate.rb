# frozen_string_literal: true

module Axn
  module OpenAPI
    # The request gate, run as Axns (the pattern axn-webhooks' `Verify` stage set) so every request —
    # including a 401/403 that never reaches a tool — emits axn's own `axn.call` event, span and log
    # line, stamped `invoked_via: openapi`, with no bespoke instrumentation. A rejection is a quiet
    # `fail!` (a failure, never paged); a strategy that RAISES (a misconfigured secret) settles as an
    # exception, reported through `Axn.config.on_exception`, and the App answers it with a generic 500.
    module Gate
      module_function

      # What a principal is recorded as. An id (String/Symbol) as itself; anything else (a JWT claims
      # object) as its class name only, so claims never reach tags, spans or logs.
      def principal_label(principal)
        case principal
        when nil then nil
        when String, Symbol then principal.to_s
        else principal.class.name || "Anonymous principal"
        end
      end

      def mount_label(mount) = (mount || :default).to_s

      FORBIDDEN = { "error" => { "message" => "Forbidden" } }.freeze

      # nil to proceed, a 403 when `Authorize` refuses, a generic 500 when the policy itself raised.
      # Shared by the mount and the controller skin so both answer a denial identically.
      def authorization_dispatch(principal:, axn_class:, operation_id:, policy: nil, mount: nil)
        result = Authorize.call(principal:, axn_class:, operation_id:, policy:, mount:)
        return nil if result.ok?

        result.outcome.failure? ? Dispatch.new(403, FORBIDDEN) : Dispatch.new(500, Dispatcher::GENERIC_500)
      end
    end

    # Authenticates one request against a mount's strategies — any of them may authenticate it, first
    # match wins — exposing who it authenticated as.
    class Authenticate
      include Axn

      # Headers carry the presented credential; strategies hold the live keys. Neither is ever logged.
      expects :request, type: Axn::OpenAPI::Request, sensitive: true
      expects :strategies, type: Array, sensitive: true
      expects :mount, type: Symbol, optional: true
      exposes :principal, optional: true, sensitive: true
      exposes :reason, type: Symbol, optional: true

      error "Authentication failed"

      dimension :mount, -> { Gate.mount_label(mount) }
      dimension :reason, -> { @reason&.to_s }, from: :result
      tag :principal, -> { Gate.principal_label(@principal) }, from: :result

      def call
        rejections = []
        strategies.each do |strategy|
          verdict = Axn::Extensions::Auth.normalize(strategy.call(request))
          next rejections << verdict.reason unless verdict.ok?

          @principal = verdict.principal
          return expose(principal: @principal)
        end

        # A presented-but-wrong credential outranks "nothing presented": with several strategies, the
        # one the caller actually tried is the one worth reporting.
        @reason = rejections.find { |r| r != :credentials_missing } || rejections.first || :rejected
        fail!("request not authenticated (#{@reason})", reason: @reason)
      end
    end

    # Decides whether an authenticated principal may call one tool: the mount's `authorize:` callable
    # when given, otherwise the tool's own `allowed_callers` (`Axn::OpenAPI.allowed_caller?`).
    class Authorize
      include Axn

      expects :principal, optional: true, sensitive: true
      expects :axn_class, type: Class
      expects :policy, optional: true
      expects :mount, type: Symbol, optional: true
      expects :operation_id, type: String

      error "Forbidden"

      dimension :mount, -> { Gate.mount_label(mount) }
      tag :principal, -> { Gate.principal_label(principal) }
      tag :operation_id, :operation_id

      def call
        allowed = policy ? policy.call(principal, axn_class) : Axn::OpenAPI.allowed_caller?(principal, axn_class)
        fail!("#{Gate.principal_label(principal) || 'anonymous'} may not call #{operation_id}") unless allowed
      end
    end
  end
end
