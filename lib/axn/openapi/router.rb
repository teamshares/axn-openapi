# frozen_string_literal: true

module Axn
  module OpenAPI
    # Maps (method, path) to a Dispatch for the mount skin. Every tool version has an exact path
    # ({prefix}/{tool}/v{n}) from the shared RouteTable; there is no bare/default/latest path. Owns
    # the pre-dispatch HTTP-layer cases (404 incl. a latest-version pointer / 405 / 400-parse).
    class Router
      # A path shaped like a tool call, so an unmatched request can be told apart from noise and its
      # tool_name recovered for the 404 latest-version pointer.
      TOOL_PATH = %r{\A/(?<name>[a-z0-9_]+)/v\d+\z}

      def initialize(tools:, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @spec_full = "#{@path_prefix}#{spec_path || Axn::OpenAPI.config.spec_path}"
        # A one-arg provider is handed the request's mount base (SCRIPT_NAME) so the served doc can
        # publish it as its `servers` base. A zero-arg provider (the documented `-> { ... }` form) is
        # still supported — see spec_dispatch's arity check.
        @spec_provider = spec_provider || ->(_script_name) { {} }

        entries = RouteTable.build(tools:, path_prefix: @path_prefix)
        @by_path = entries.to_h { |e| [e.path, e.axn] }
        # tool_name => newest entry, for the 404 pointer. Entries are asc by version, so `last` wins.
        @latest_by_name = entries.to_h { |e| [e.axn.tool_name(:openapi), e] }
      end

      def route(http_method:, path:, raw_body:, ambient_context: {}, script_name: "")
        return spec_dispatch(http_method, script_name) if path == @spec_full

        axn = @by_path[path]
        return not_found(path) unless axn
        return error(405, "Method not allowed", allow: "POST") unless http_method == "POST"

        # Shared parser (Dispatcher.parse_body) so the mount and controller skins can't diverge on
        # what counts as malformed: nil => malformed/non-object body => the shared 400 envelope.
        params = Dispatcher.parse_body(raw_body)
        return Dispatcher.malformed_body_dispatch if params.nil?

        Dispatcher.call(axn_class: axn, params:, ambient_context:)
      end

      private

      def spec_dispatch(http_method, script_name)
        return error(405, "Method not allowed", allow: "GET") unless http_method == "GET"

        # Honor both provider shapes: a zero-arity `-> { ... }` (the documented form) is called with no
        # args; anything taking an argument receives the mount base. A Proc/lambda/Method exposes its
        # OWN arity directly (reading `method(:call).arity` would wrongly report Proc#call's -1); a
        # plain callable object (`def call`) doesn't respond to `#arity`, so read it off its #call.
        callable = @spec_provider.respond_to?(:arity) ? @spec_provider : @spec_provider.method(:call)
        doc = callable.arity.zero? ? @spec_provider.call : @spec_provider.call(script_name)
        Dispatch.new(200, doc)
      end

      # A known tool_name at a non-existent version points at the latest available version;
      # anything else is a plain unknown-tool 404. Pointer is error-body only, never a route. Once
      # the path is confirmed tool-shaped, the tool-not-found message names the tool rather than
      # echoing the raw (versioned) path, so it can't be mistaken for a version pointer itself.
      def not_found(path)
        rel = @path_prefix.empty? ? path : path.delete_prefix(@path_prefix)
        match = TOOL_PATH.match(rel)
        return error(404, "Unknown tool for path #{path}") unless match

        latest = @latest_by_name[match[:name]]
        return error(404, "Unknown tool: #{match[:name]}") unless latest

        error(404, "Unknown version for tool '#{match[:name]}'. Latest available: #{latest.path}.")
      end

      # `allow:` sets the `Allow` header required on a 405 (the methods the path does support).
      def error(status, message, allow: nil)
        headers = allow ? { "allow" => allow } : {}
        Dispatch.new(status, { "error" => { "message" => message } }, headers)
      end
    end
  end
end
