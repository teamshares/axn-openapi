# frozen_string_literal: true

module Axn
  module OpenAPI
    # Assembles the OpenAPI 3.1 document from axn-core reflection. Near-mechanical: one POST path
    # per tool, requestBody = input_schema, 200 = output_schema, shared Error component for
    # failures, and the semantic hints as an x-axn-semantic-hints vendor extension.
    class SpecGenerator
      ERROR_REF = { "$ref" => "#/components/schemas/Error" }.freeze

      ERROR_SCHEMA = {
        "type" => "object",
        "properties" => {
          "error" => {
            "type" => "object",
            "properties" => {
              "message" => { "type" => "string" },
              "field_errors" => {
                "type" => "array",
                "items" => {
                  "type" => "object",
                  "properties" => { "field" => { "type" => "string" }, "message" => { "type" => "string" } },
                },
              },
            },
            "required" => ["message"],
          },
        },
        "required" => ["error"],
      }.freeze

      def initialize(tools:, path_prefix: nil, info: nil)
        @tools = tools
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @info = info || default_info
      end

      def generate
        entries = RouteTable.build(tools: @tools, path_prefix: @path_prefix)
        {
          "openapi" => "3.1.0",
          "info" => @info,
          "paths" => entries.to_h { |entry| [entry.path, path_item(entry)] },
          "components" => { "schemas" => { "Error" => ERROR_SCHEMA } },
        }
      end

      private

      def default_info
        info = { "title" => Axn::OpenAPI.config.info_title, "version" => Axn::OpenAPI.config.info_version }
        desc = Axn::OpenAPI.config.info_description
        info["description"] = desc if desc
        info
      end

      def path_item(entry)
        axn = entry.axn
        op = {
          "operationId" => entry.operation_id,
          "requestBody" => { "required" => true, "content" => { "application/json" => { "schema" => axn.input_schema } } },
          "responses" => {
            "200" => { "description" => "Success", "content" => { "application/json" => { "schema" => axn.output_schema } } },
            "400" => error_response("Invalid request"),
            "422" => error_response("Operation could not be completed"),
            "500" => error_response("Internal server error"),
          },
        }
        op["summary"] = axn.description if axn.description
        hints = axn._semantic_hints.map(&:to_s)
        op["x-axn-semantic-hints"] = hints unless hints.empty?
        { "post" => op }
      end

      def error_response(description)
        { "description" => description, "content" => { "application/json" => { "schema" => ERROR_REF } } }
      end
    end
  end
end
