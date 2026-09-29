# frozen_string_literal: true

module Axn
  module OpenAPI
    # Maps (method, path) to a Dispatch for the mount skin. Every tool version has an exact path
    # ({prefix}/{tool}/v{n}) from the shared RouteTable; there is no bare/default/latest path. Owns
    # the pre-dispatch HTTP-layer cases (404 incl. a latest-version pointer / 405 / 400-parse).
    class Router
      # A path shaped like a tool call, so an unmatched request can be told apart from noise and its
      # tool_name recovered for the 404 latest-version pointer.
      TOOL_PATH = %r{\A/(?<name>[a-z0-9_-]+)/v\d+\z}

      def initialize(tools:, path_prefix: nil, spec_path: nil, spec_provider: nil, path_segment_style: nil)
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @spec_full = "#{@path_prefix}#{spec_path || Axn::OpenAPI.config.spec_path}"
        yaml_path = Axn::OpenAPI.config.spec_yaml_path
        @spec_yaml_full = yaml_path && "#{@path_prefix}#{yaml_path}"
        # A one-arg provider is handed the request's mount base (SCRIPT_NAME) so the served doc can
        # publish it as its `servers` base. A zero-arg provider (the documented `-> { ... }` form) is
        # still supported — see spec_dispatch's arity check.
        @spec_provider = spec_provider || ->(_script_name) { {} }

        entries = RouteTable.build(tools:, path_prefix: @path_prefix,
                                   path_segment_style: path_segment_style || Axn::OpenAPI.config.path_segment_style)
        @by_path = entries.to_h { |e| [e.path, e] }
        # path segment => newest entry, for the 404 pointer. Entries are asc by version, so `last` wins.
        @latest_by_segment = entries.to_h { |e| [e.segment, e] }

        # The spec endpoints are matched before the tool map, so a spec path equal to a tool route would
        # silently shadow that tool (GET serves the doc, POST 405s) while the doc still advertises the
        # tool's POST there. Fail loud at construction rather than ship that contradiction.
        check_spec_path!(:spec_path, @spec_full)
        check_spec_path!(:spec_yaml_path, @spec_yaml_full) if @spec_yaml_full
        return unless @spec_yaml_full == @spec_full

        raise Axn::OpenAPI::Error, "spec_yaml_path #{@spec_yaml_full.inspect} is also the spec_path; configure distinct paths"
      end

      def spec_path?(path) = path == @spec_full || (!@spec_yaml_full.nil? && path == @spec_yaml_full)

      # `authorize:` (optional) is called with the matched RouteEntry once the tool is known and
      # returns nil to proceed or a Dispatch (403) to stop — ahead of the verb check, so a forbidden
      # caller learns nothing about what the path would accept. `raw_body:` and `ambient_context:` may
      # each be a value or a zero-arity callable, evaluated only when a tool is actually dispatched —
      # so a 403/404/405/spec request never reads (or buffers) the request body.
      def route(http_method:, path:, raw_body:, ambient_context: {}, script_name: "", authorize: nil)
        return spec_dispatch(http_method, script_name, path == @spec_full ? :json : :yaml) if spec_path?(path)

        entry = @by_path[path]
        return not_found(path, script_name, authorize) unless entry

        denied = authorize&.call(entry)
        return denied if denied
        return error(405, "Method not allowed", allow: "POST") unless http_method == "POST"

        # Shared parser (Dispatcher.parse_body) so the mount and controller skins can't diverge on
        # what counts as malformed: nil => malformed/non-object body => the shared 400 envelope.
        raw_body = raw_body.call if raw_body.respond_to?(:call)
        params = Dispatcher.parse_body(raw_body)
        return Dispatcher.malformed_body_dispatch if params.nil?

        ambient_context = ambient_context.call if ambient_context.respond_to?(:call)
        Dispatcher.call(axn_class: entry.axn, params:, ambient_context:)
      end

      private

      def check_spec_path!(setting, full)
        return unless @by_path.key?(full)

        raise Axn::OpenAPI::Error,
              "#{setting} #{full.inspect} collides with the tool route for " \
              "#{@by_path[full].axn.tool_name(:openapi).inspect}; configure a non-colliding #{setting}"
      end

      def spec_dispatch(http_method, script_name, format)
        return error(405, "Method not allowed", allow: "GET") unless http_method == "GET"

        # Honor both provider shapes: a zero-arity `-> { ... }` (the documented form) is called with no
        # args; anything taking an argument receives the mount base. A Proc/lambda/Method exposes its
        # OWN arity directly (reading `method(:call).arity` would wrongly report Proc#call's -1); a
        # plain callable object (`def call`) doesn't respond to `#arity`, so read it off its #call.
        callable = @spec_provider.respond_to?(:arity) ? @spec_provider : @spec_provider.method(:call)
        doc = callable.arity.zero? ? @spec_provider.call : @spec_provider.call(script_name)
        Dispatch.new(200, doc, {}, format)
      end

      # A known tool_name at a non-existent version points at the latest available version;
      # anything else is a plain unknown-tool 404. Pointer is error-body only, never a route. Once
      # the path is confirmed tool-shaped, the tool-not-found message names the tool rather than
      # echoing the raw (versioned) path, so it can't be mistaken for a version pointer itself.
      # `authorize` gates the latest-version pointer: a caller forbidden from the tool gets the plain
      # "Unknown tool" instead of being pointed at a path it may not call; a policy error still 500s.
      def not_found(path, script_name, authorize = nil)
        rel = @path_prefix.empty? ? path : path.delete_prefix(@path_prefix)
        match = TOOL_PATH.match(rel)
        # Don't echo the raw request path — it's request-derived (and possibly not even valid UTF-8),
        # and echoing it is the kind of untrusted content that shouldn't ride into a response body.
        return error(404, "Unknown tool") unless match

        latest = @latest_by_segment[match[:name]]
        return error(404, "Unknown tool: #{match[:name]}") if latest.nil?

        # A forbidden caller (403) gets exactly what a nonexistent tool gets, so the 404 can't confirm
        # it. Any other refusal — the generic 500 of a policy that raised — is passed through as it
        # would be on a real route, so a misconfigured policy isn't masked as a missing version.
        denied = authorize&.call(latest)
        return denied.status == 403 ? error(404, "Unknown tool: #{match[:name]}") : denied if denied

        # Prepend the Rack mount base (SCRIPT_NAME) so the pointer is the REAL externally-visible URL
        # (e.g. /api/greeter/v2), not the mount-relative path (/greeter/v2) that 404s at the origin root.
        error(404, "Unknown version for tool '#{match[:name]}'. Latest available: #{script_name}#{latest.path}.")
      end

      # `allow:` sets the `Allow` header required on a 405 (the methods the path does support).
      def error(status, message, allow: nil)
        headers = allow ? { "allow" => allow } : {}
        Dispatch.new(status, { "error" => { "message" => message } }, headers)
      end
    end
  end
end
