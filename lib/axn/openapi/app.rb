# frozen_string_literal: true

module Axn
  module OpenAPI
    # A framework-agnostic Rack app. Directly `mount`able in a Rails routes file
    # (`mount Axn::OpenAPI::App.new(...) => "/api"`) or `run`-able in a bare Rack::Builder — the
    # mount point is the path prefix. `context:` maps the Rack env to the trusted ambient_context
    # (e.g. current_user), the auth seam the gem offers but does not own.
    class App
      def initialize(tools: nil, context: nil, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @tools = tools || Axn::OpenAPI.tools
        @context = context || ->(_env) { {} }
        # The provider is handed the request's mount base (SCRIPT_NAME) at serve time so the served
        # doc can publish it as its `servers` base — see Request#script_name / SpecGenerator.
        provider = spec_provider || ->(base) { SpecGenerator.new(tools: @tools, path_prefix:, servers_base: base).generate }
        @router = Router.new(tools: @tools, path_prefix:, spec_path:, spec_provider: provider)
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
        Response.json(dispatch.body, status: dispatch.status).to_rack
      end
    end
  end
end
