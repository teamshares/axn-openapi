# frozen_string_literal: true

module Axn
  module OpenAPI
    # A Rails-agnostic view of an inbound HTTP request, built from a Rack env or directly in tests.
    # `script_name` is the Rack mount base (env["SCRIPT_NAME"]) — the prefix Rack strips off PATH_INFO
    # when the app is mounted below the origin root; it's what the served OpenAPI doc needs as its
    # `servers` base so generated clients target the real (mounted) URL.
    Request = Data.define(:http_method, :path, :raw_body, :script_name) do
      def self.from_rack(env)
        input = env["rack.input"]
        raw_body = input ? input.read.to_s : ""
        begin
          input&.rewind
        rescue StandardError
          nil # rewind is a courtesy; raw_body is already captured
        end
        new(http_method: env["REQUEST_METHOD"].to_s.upcase, path: env["PATH_INFO"].to_s, raw_body:,
            script_name: env["SCRIPT_NAME"].to_s)
      end
    end
  end
end
