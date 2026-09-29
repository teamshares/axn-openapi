# frozen_string_literal: true

require "json"

module Axn
  module OpenAPI
    # A Rails-agnostic HTTP response value: status + JSON (or YAML) body + headers. Mirrors
    # axn-webhooks' Response. #to_rack renders the [status, headers, [body]] triple.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status: 200, body: "", headers: {})
        @status = status
        @body = body.to_s
        @headers = headers.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v.to_s }
        freeze
      end

      # Render a Dispatch in its format.
      def self.for(dispatch)
        render = dispatch.format == :yaml ? method(:yaml) : method(:json)
        render.call(dispatch.body, status: dispatch.status, headers: dispatch.headers)
      end

      # Build a YAML response (`application/yaml`, RFC 9512) from a JSON-ready Hash.
      def self.yaml(data, status: 200, headers: {})
        new(status:, body: SpecGenerator.to_yaml(data), headers: { "content-type" => "application/yaml" }.merge(headers))
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
