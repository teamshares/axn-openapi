# frozen_string_literal: true

module Axn
  module OpenAPI
    # A Rails-agnostic view of an inbound HTTP request, built from a Rack env or directly in tests.
    # `script_name` is the Rack mount base (env["SCRIPT_NAME"]) — the prefix Rack strips off PATH_INFO
    # when the app is mounted below the origin root; it's what the served OpenAPI doc needs as its
    # `servers` base so generated clients target the real (mounted) URL.
    #
    # `#header(name)` (case-insensitive) is the one method axn core's `Axn::Extensions::Auth`
    # strategies read, so this object is handed to them directly.
    #
    # `#raw_body` is read from `rack.input` on first call, not at construction: an anonymous request
    # the gate will 401 (or a 403/404/405/spec request) never has its body buffered. A strategy that
    # needs the body (a signature check) can still call it; the read is memoized and shared.
    # The memo behind Request#raw_body — a mutable cell, since the Data holding it is frozen.
    class RequestBody
      def initialize(input, value = nil)
        @input = input
        @value = value
      end

      def read? = !@value.nil?

      def read
        @value ||= begin
          value = @input ? @input.read.to_s : ""
          begin
            @input&.rewind
          rescue StandardError
            nil # rewind is a courtesy; the value is already captured
          end
          value
        end
      end

      def inspect = "#<#{self.class.name} [REDACTED]>"
    end

    Request = Data.define(:http_method, :path, :body, :script_name, :headers) do
      def self.from_rack(env)
        new(http_method: env["REQUEST_METHOD"].to_s.upcase, path: env["PATH_INFO"].to_s,
            raw_body: RequestBody.new(env["rack.input"]), script_name: env["SCRIPT_NAME"].to_s, headers: headers_from(env))
      end

      # Every request header arrives as HTTP_<NAME> except Rack's two un-prefixed content headers.
      def self.headers_from(env)
        env.each_with_object({}) do |(key, value), headers|
          name = if key.start_with?("HTTP_") then key.delete_prefix("HTTP_").downcase.tr("_", "-")
                 elsif key == "CONTENT_TYPE" then "content-type"
                 elsif key == "CONTENT_LENGTH" then "content-length"
                 end
          headers[name] = value if name && value.is_a?(String)
        end
      end

      # `raw_body:` is a String, or a RequestBody reading a Rack input on demand.
      def initialize(http_method:, path:, raw_body:, script_name:, headers: {})
        super(http_method:, path:, body: raw_body.is_a?(RequestBody) ? raw_body : RequestBody.new(nil, raw_body.to_s), script_name:,
              headers: headers.to_h { |name, value| [name.to_s.downcase, value] }.freeze)
      end

      def header(name) = headers[name.to_s.downcase]

      def raw_body = body.read

      # Headers carry credentials (Authorization, API keys) and the body is caller data of unknown
      # sensitivity; axn's auto-logging and exception reports render inputs through #inspect, so
      # neither may ever appear here. Rendering must not force the body read either.
      def inspect
        size = body.read? ? " (#{raw_body.bytesize}b)" : ""
        "#<#{self.class.name} #{http_method} #{script_name}#{path} headers=[REDACTED] raw_body=[REDACTED]#{size}>"
      end
      alias_method :to_s, :inspect

      # PP walks Data members directly rather than calling #inspect.
      def pretty_print(printer) = printer.text(inspect)
    end
  end
end
