# frozen_string_literal: true

module Axn
  module OpenAPI
    # A framework-agnostic Rack app. Directly `mount`able in a Rails routes file
    # (`mount Axn::OpenAPI::App.new(...) => "/api"`) or `run`-able in a bare Rack::Builder — the
    # mount point is the path prefix. `context:` maps the Rack env to the trusted ambient_context
    # (e.g. current_user), the auth seam the gem offers but does not own.
    class App
      def initialize(tools: nil, context: nil, path_prefix: nil, spec_path: nil, spec_provider: nil)
        # Snapshot the tool list at build time (dup + freeze) so a caller mutating the array they
        # passed can't split the two consumers: the router builds its route table once here, while the
        # default spec provider regenerates from @tools per request — a later add/remove would then
        # advertise a route that 404s (or hide one that works). Both now share this frozen snapshot.
        @tools = (tools || Axn::OpenAPI.tools).dup.freeze
        @context = context || ->(_env) { {} }
        # Resolve the prefix ONCE and hand the SAME value to both the router and the spec generator.
        # Otherwise a nil (default) prefix is captured by the router at build time but re-resolved by
        # the generator on each spec request — so a later change to `Axn::OpenAPI.config.path_prefix`
        # (e.g. while building several differently-configured apps) would split routing from the doc.
        # dup + freeze so that even a mutable source String mutated after construction can't drift the
        # captured value (`.to_s` alone returns the same object for a String).
        resolved_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s.dup.freeze
        # The provider is handed the request's mount base (SCRIPT_NAME) at serve time so the served
        # doc can publish it as its `servers` base — see Request#script_name / SpecGenerator.
        provider = spec_provider || ->(base) { SpecGenerator.new(tools: @tools, path_prefix: resolved_prefix, servers_base: base).generate }
        @router = Router.new(tools: @tools, path_prefix: resolved_prefix, spec_path:, spec_provider: provider)
      end

      def call(env)
        request = Request.from_rack(env)
        dispatch = @router.route(
          http_method: request.http_method,
          path: request.path,
          raw_body: request.raw_body,
          ambient_context: @context.call(env),
          script_name: request.script_name,
        )
        Response.json(dispatch.body, status: dispatch.status, headers: dispatch.headers).to_rack
      end
    end
  end
end
