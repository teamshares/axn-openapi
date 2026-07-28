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

      def initialize(tools:, path_prefix: nil, info: nil, servers_base: nil)
        @tools = tools
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @info = info || default_info
        @servers_base = servers_base.to_s
      end

      def generate
        entries = RouteTable.build(tools: @tools, path_prefix: @path_prefix)
        doc = { "openapi" => "3.1.0", "info" => @info }
        # The doc's paths are mount-RELATIVE (they carry `path_prefix` but not the Rack mount point).
        # When the app is mounted below the origin root (e.g. `/api`), Rack strips that mount point
        # into SCRIPT_NAME, so without a `servers` base OpenAPI defaults the server to `/` and codegen
        # calls the wrong root-level URL. Publish the mount base as the server when known; omit it for
        # a root mount ("" → OpenAPI's `/` default is already correct).
        doc["servers"] = [{ "url" => @servers_base }] unless @servers_base.empty?
        doc["paths"] = entries.to_h { |entry| [entry.path, path_item(entry)] }
        doc["components"] = { "schemas" => { "Error" => ERROR_SCHEMA } }
        doc
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
        input_schema = axn.input_schema
        op = {
          "operationId" => entry.operation_id,
          "requestBody" => request_body(input_schema),
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

      # `required` is derived from the contract, not hardcoded true: a tool with no required inbound
      # fields — an ambient-context-only tool (empty input schema), or one whose inputs are all
      # optional — accepts a blank body (the router parses a blank body as `{}`), so forcing a body
      # would make OpenAPI validators and generated clients reject a request that succeeds at runtime.
      def request_body(input_schema)
        schema = input_schema
        # When the adapter rejects unknown top-level fields at runtime (reject_undeclared_inputs),
        # reflect that in the published schema — otherwise OpenAPI validators / generated clients
        # accept or send a payload the mounted API will 400. Core leaves additionalProperties at JSON
        # Schema's permissive default; tighten it to match. `merge` returns a new Hash (never mutates
        # the core-owned input_schema). Top-level only — that's the scope of the runtime check.
        schema = schema.merge(additionalProperties: false) if Axn::OpenAPI.config.reject_undeclared_inputs
        {
          "required" => Array(input_schema[:required]).any?,
          "content" => { "application/json" => { "schema" => schema } },
        }
      end

      def error_response(description)
        { "description" => description, "content" => { "application/json" => { "schema" => ERROR_REF } } }
      end
    end
  end
end
