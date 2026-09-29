# frozen_string_literal: true

module Axn
  module OpenAPI
    # A framework-agnostic Rack app. Directly `mount`able in a Rails routes file
    # (`mount Axn::OpenAPI.app(auth: ...) => "/api"`) or `run`-able in a bare Rack::Builder — the
    # mount point is the path prefix.
    #
    # Per request: authenticate (unless `auth: :none`, or the document path with `public_spec: true`)
    # BEFORE routing, so an unauthenticated caller can't tell a real tool path from a 404; then route;
    # then, once the tool is known, authorize it (403). `context:` maps the Rack env — and, with a
    # second parameter, the authenticated principal — to the trusted ambient_context, evaluated only
    # when a tool is actually dispatched.
    class App
      UNAUTHORIZED = { "error" => { "message" => "Unauthorized" } }.freeze

      attr_reader :mount

      def initialize(auth: nil, tools: nil, mount: nil, authorize: nil, context: nil, public_spec: false, info: nil,
                     path_prefix: nil, spec_path: nil, spec_provider: nil)
        raise Axn::OpenAPI::Error, "mount: must be a Symbol (or nil for the default mount)" unless mount.nil? || mount.is_a?(Symbol)

        @mount = mount
        @strategies = Auth.strategies_for(auth)
        # Snapshot the tool list at build time (dup + freeze) so a caller mutating the array they
        # passed can't split the two consumers: the router builds its route table once here, while the
        # default spec provider regenerates from @tools per request — a later add/remove would then
        # advertise a route that 404s (or hide one that works). Both now share this frozen snapshot.
        @tools = (tools ? explicit_tools!(tools) : Axn::OpenAPI.tools(mount:)).dup.freeze
        @authorize = authorize
        @context = context || ->(_env) { {} }
        @context_takes_principal = takes_second_argument?(@context)
        @public_spec = public_spec
        check_access_policy!

        @unauthorized_headers = Auth.unauthorized_headers(@strategies).freeze
        security_schemes = Auth.security_schemes(@strategies)
        # Resolve the prefix ONCE and hand the SAME value to both the router and the spec generator.
        # Otherwise a nil (default) prefix is captured by the router at build time but re-resolved by
        # the generator on each spec request — so a later change to `Axn::OpenAPI.config.path_prefix`
        # (e.g. while building several differently-configured apps) would split routing from the doc.
        # dup + freeze so that even a mutable source String mutated after construction can't drift the
        # captured value (`.to_s` alone returns the same object for a String).
        resolved_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s.dup.freeze
        # Captured once for the same reason as the prefix: routing and the served document must agree.
        segment_style = Axn::OpenAPI.config.path_segment_style
        # The provider is handed the request's mount base (SCRIPT_NAME) at serve time so the served
        # doc can publish it as its `servers` base — see Request#script_name / SpecGenerator.
        provider = spec_provider || lambda { |base|
          SpecGenerator.new(tools: @tools, path_prefix: resolved_prefix, servers_base: base, info:,
                            security_schemes:, authorize_all: !@authorize.nil?, path_segment_style: segment_style).generate
        }
        @router = Router.new(tools: @tools, path_prefix: resolved_prefix, spec_path:, spec_provider: provider,
                             path_segment_style: segment_style)
      end

      def call(env)
        request = Request.from_rack(env)
        dispatch = Axn::Extensions::InvokedVia.with(:openapi) { handle(request, env) }
        # Render boundary: guarantee the body is JSON-encodable (covers router 404/spec-doc bodies too,
        # not just Dispatcher.call's) so nothing raises out of Response.json / escapes the Rack app.
        dispatch = Dispatcher.ensure_encodable(dispatch)
        Response.json(dispatch.body, status: dispatch.status, headers: dispatch.headers).to_rack
      end

      private

      def handle(request, env)
        principal = nil
        if authenticate?(request)
          result = Authenticate.call(request:, strategies: @strategies, mount: @mount)
          return Dispatch.new(401, UNAUTHORIZED, @unauthorized_headers) if result.outcome.failure?
          return Dispatch.new(500, Dispatcher::GENERIC_500) unless result.ok?

          principal = result.principal
        end
        env[Axn::OpenAPI::PRINCIPAL_ENV_KEY] = principal

        @router.route(
          http_method: request.http_method,
          path: request.path,
          raw_body: request.raw_body,
          ambient_context: -> { ambient_context_for(env, principal) },
          script_name: request.script_name,
          authorize: authorizer_for(principal),
        )
      end

      def authenticate?(request)
        return false if @strategies.empty?

        !(@public_spec && @router.spec_path?(request.path))
      end

      # Nothing to authorize under `auth: :none` (no caller is identified; the build refuses tools that
      # would need it). Otherwise the 403 check, once the Router knows which tool was asked for.
      def authorizer_for(principal)
        return nil if @strategies.empty?

        lambda do |entry|
          Gate.authorization_dispatch(principal:, axn_class: entry.axn, operation_id: entry.operation_id,
                                      policy: @authorize, mount: @mount)
        end
      end

      # A `context:` that can take a second positional argument (a required or optional one, or a
      # splat) also gets the principal; anything else gets the env alone (the original shape) — so
      # `->(env = nil)` / `def call(env = nil)` keep working. Read off `parameters`, not `arity`:
      # an optional argument makes arity negative whether or not a second one would be accepted.
      def ambient_context_for(env, principal)
        @context_takes_principal ? @context.call(env, principal) : @context.call(env)
      end

      def takes_second_argument?(callable)
        params = (callable.respond_to?(:parameters) ? callable : callable.method(:call)).parameters
        params.any? { |kind, _| kind == :rest } || params.count { |kind, _| %i[req opt].include?(kind) } >= 2
      end

      def mount_label = @mount.nil? ? "the default mount" : "mount #{@mount.inspect}"

      def explicit_tools!(tools)
        tools.each do |axn|
          declared = Axn::OpenAPI.resolve_override_for(axn, :mount)
          next if declared.nil? || declared == @mount

          raise Axn::OpenAPI::Error,
                "#{axn} declares `tool openapi: { mount: #{declared.inspect} }` and can't be served by " \
                "#{mount_label}; build it with Axn::OpenAPI.app(mount: #{declared.inspect}, ...)"
        end
        tools
      end

      # Contradictions between a mount's auth and what its tools require, caught at boot.
      def check_access_policy!
        restricted = @tools.select { |axn| Axn::OpenAPI.resolve_override_for(axn, :allowed_callers) }
        if @strategies.empty?
          raise Axn::OpenAPI::Error, "authorize: has no principal to check under auth: :none; configure an auth strategy" if @authorize
          return if restricted.empty?

          raise Axn::OpenAPI::Error,
                "#{restricted.first} declares allowed_callers, but #{mount_label} is built with auth: :none " \
                "(no caller is ever identified); configure an auth strategy"
        end

        known = Auth.known_principals(@strategies)
        return if known.nil? || @authorize

        restricted.each do |axn|
          unknown = Axn::OpenAPI.resolve_override_for(axn, :allowed_callers).map(&:to_s) - known
          next if unknown.empty?

          raise Axn::OpenAPI::Error,
                "#{axn} allows #{unknown.map(&:inspect).join(', ')}, which no auth strategy on " \
                "#{mount_label} can authenticate as (known: #{known.map(&:inspect).join(', ')})"
        end
      end
    end
  end
end
