# frozen_string_literal: true

module Axn
  module OpenAPI
    # A framework-agnostic Rack app. Directly `mount`able in a Rails routes file
    # (`mount Axn::OpenAPI::App.new(...) => "/api"`) or `run`-able in a bare Rack::Builder — the
    # mount point is the path prefix. `context:` maps the Rack env to the trusted ambient_context
    # (e.g. current_user), the auth seam the gem offers but does not own.
    class App
      def initialize(tools: nil, context: nil, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @tools = tools || Axn.tools_for(:openapi)
        @context = context || ->(_env) { {} }
        provider = spec_provider || -> { SpecGenerator.new(tools: @tools, path_prefix:).generate }
        @router = Router.new(tools: @tools, path_prefix:, spec_path:, spec_provider: provider)
      end

      def call(env)
        request = Request.from_rack(env)
        dispatch = @router.route(
          http_method: request.http_method,
          path: request.path,
          raw_body: request.raw_body,
          ambient_context: @context.call(env),
        )
        Response.json(dispatch.body, status: dispatch.status).to_rack
      end
    end
  end
end
