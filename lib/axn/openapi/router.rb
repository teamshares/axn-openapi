# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # Maps (method, path) to a Dispatch for the mount skin: strips the prefix, serves the spec,
    # looks the tool up by tool_name, and owns the pre-dispatch HTTP-layer cases (404/405/400-parse).
    class Router
      PARSE_ERROR = Object.new.freeze
      private_constant :PARSE_ERROR

      def initialize(tools:, path_prefix: nil, spec_path: nil, spec_provider: nil)
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @spec_path = spec_path || Axn::OpenAPI.config.spec_path
        @spec_provider = spec_provider || -> { {} }
        @by_name = tools.to_h { |axn| [axn.tool_name(:openapi), axn] }
      end

      def route(http_method:, path:, raw_body:, ambient_context: {})
        rel = strip_prefix(path)
        return spec_dispatch(http_method) if rel == @spec_path

        tool = @by_name[rel.delete_prefix("/")]
        return error(404, "Unknown tool: #{rel.delete_prefix('/')}") unless tool
        return error(405, "Method not allowed") unless http_method == "POST"

        params = parse_json(raw_body)
        return error(400, "Malformed JSON request body") if params.equal?(PARSE_ERROR)

        Dispatcher.call(axn_class: tool, params:, ambient_context:)
      end

      private

      def spec_dispatch(http_method)
        return error(405, "Method not allowed") unless http_method == "GET"

        Dispatch.new(200, @spec_provider.call)
      end

      def strip_prefix(path)
        return path if @path_prefix.empty?

        path.start_with?(@path_prefix) ? path.delete_prefix(@path_prefix) : path
      end

      def parse_json(raw_body)
        return {} if raw_body.nil? || raw_body.strip.empty?

        parsed = JSON.parse(raw_body)
        parsed.is_a?(Hash) ? parsed : PARSE_ERROR
      rescue JSON::ParserError
        PARSE_ERROR
      end

      def error(status, message) = Dispatch.new(status, { "error" => { "message" => message } })
    end
  end
end
