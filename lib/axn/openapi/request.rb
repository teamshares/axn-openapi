# frozen_string_literal: true

module Axn
  module OpenAPI
    # A Rails-agnostic view of an inbound HTTP request, built from a Rack env or directly in tests.
    Request = Data.define(:http_method, :path, :raw_body) do
      def self.from_rack(env)
        input = env["rack.input"]
        raw_body = input ? input.read.to_s : ""
        begin
          input&.rewind
        rescue StandardError
          nil # rewind is a courtesy; raw_body is already captured
        end
        new(http_method: env["REQUEST_METHOD"].to_s.upcase, path: env["PATH_INFO"].to_s, raw_body:)
      end
    end
  end
end
