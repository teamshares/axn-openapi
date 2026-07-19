# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # A Rails-agnostic HTTP response value: status + JSON body + headers. Mirrors
    # axn-webhooks' Response. #to_rack renders the [status, headers, [body]] triple.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status: 200, body: "", headers: {})
        @status = status
        @body = body.to_s
        @headers = headers.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v.to_s }
        freeze
      end

      # Build a JSON response from a Ruby Hash/Array (nil body → empty object body).
      def self.json(data, status: 200, headers: {})
        new(status:, body: JSON.generate(data.nil? ? {} : data),
            headers: { "content-type" => "application/json" }.merge(headers))
      end

      def ==(other)
        other.is_a?(self.class) && status == other.status && body == other.body && headers == other.headers
      end

      def to_rack = [status, headers.dup, [body]]
    end
  end
end
