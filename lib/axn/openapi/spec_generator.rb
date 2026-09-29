# frozen_string_literal: true

require "json"
require "yaml"

module Axn
  module OpenAPI
    # Assembles the OpenAPI 3.1 document from axn-core reflection. Near-mechanical: one POST path
    # per tool, requestBody = input_schema, 200 = output_schema, shared Error component for
    # failures, and the semantic hints as an x-axn-semantic-hints vendor extension.
    class SpecGenerator
      # YAML of the document exactly as a JSON client receives it: the JSON round-trip turns the Symbol
      # keys core's reflection emits into Strings (YAML would otherwise write `:required`).
      def self.to_yaml(doc) = YAML.dump(JSON.parse(JSON.generate(doc)))

      # `security_schemes:` (name => OpenAPI security scheme, from Auth.security_schemes) documents how
      # the mount authenticates: published as `components.securitySchemes` plus a top-level `security`
      # listing them as alternatives, and a 401 on every operation. A 403 is documented where the
      # tool declares `allowed_callers`, or on every operation when `authorize_all:` (a mount-level
      # `authorize:` callable may refuse any of them). `info:` is merged over the configured info_*.
      def initialize(tools:, path_prefix: nil, info: nil, servers_base: nil, security_schemes: {}, authorize_all: false,
                     path_segment_style: nil)
        @tools = tools
        @path_prefix = (path_prefix || Axn::OpenAPI.config.path_prefix).to_s
        @info = default_info.merge(Auth.deep_stringify(info || {}))
        @servers_base = servers_base.to_s
        @security_schemes = security_schemes || {}
        @authorize_all = authorize_all
        @path_segment_style = path_segment_style || Axn::OpenAPI.config.path_segment_style
      end

      def generate
        entries = RouteTable.build(tools: @tools, path_prefix: @path_prefix, path_segment_style: @path_segment_style)
        doc = { "openapi" => "3.1.0", "info" => @info }
        # The doc's paths are mount-RELATIVE (they carry `path_prefix` but not the Rack mount point).
        # When the app is mounted below the origin root (e.g. `/api`), Rack strips that mount point
        # into SCRIPT_NAME, so without a `servers` base OpenAPI defaults the server to `/` and codegen
        # calls the wrong root-level URL. Publish the mount base as the server when known; omit it for
        # a root mount ("" → OpenAPI's `/` default is already correct).
        doc["servers"] = [{ "url" => @servers_base }] unless @servers_base.empty?
        # Newest version of each tool IN THIS DOCUMENT: an older one is documented deprecated (unless
        # the tool sets `deprecated` itself). Document-local, like operationId.
        @latest_versions = entries.to_h { |entry| [entry.axn.tool_name(:openapi), entry.axn.tool_version] }
        doc["paths"] = entries.to_h { |entry| [entry.path, path_item(entry)] }
        tags = entries.flat_map { |entry| Array(Axn::OpenAPI.resolve_override_for(entry.axn, :operation_tags)) }.uniq
        doc["tags"] = tags.map { |name| { "name" => name } } unless tags.empty?
        doc["components"] = { "schemas" => { "Error" => error_schema } }
        unless @security_schemes.empty?
          # Fresh copies per document (see error_ref) — schemes may be shared frozen objects.
          doc["components"]["securitySchemes"] = Auth.deep_stringify(@security_schemes)
          doc["security"] = @security_schemes.keys.map { |name| { name => [] } }
        end
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
          "requestBody" => request_body(input_schema, axn),
          "responses" => {
            "200" => { "description" => "Success",
                       "content" => { "application/json" => media_type(axn.output_schema, axn, :response_example) } },
            "400" => error_response("Invalid request"),
            "422" => error_response("Operation could not be completed"),
            "500" => error_response("Internal server error"),
          },
        }
        op["responses"]["401"] = error_response("Unauthorized") unless @security_schemes.empty?
        op["responses"]["403"] = error_response("Forbidden") if forbiddable?(axn)
        op["summary"] = axn.description if axn.description
        tags = Axn::OpenAPI.resolve_override_for(axn, :operation_tags)
        op["tags"] = tags.dup if tags
        op["deprecated"] = true if deprecated?(axn)
        hints = axn._semantic_hints.map(&:to_s)
        op["x-axn-semantic-hints"] = hints unless hints.empty?
        { "post" => op }
      end

      def deprecated?(axn)
        forced = Axn::OpenAPI.resolve_override_for(axn, :deprecated)
        return forced unless forced.nil?

        axn.tool_version < @latest_versions.fetch(axn.tool_name(:openapi))
      end

      # A media type object, with the tool's declared example (if any) as `examples.default`. The
      # example is deep-stringified into a fresh copy per document (see error_ref).
      def media_type(schema, axn, example_setting)
        media = { "schema" => schema }
        example = Axn::OpenAPI.resolve_override_for(axn, example_setting)
        media["examples"] = { "default" => { "value" => Auth.deep_stringify(example) } } if example
        media
      end

      def forbiddable?(axn)
        return false if @security_schemes.empty?

        @authorize_all || !Axn::OpenAPI.resolve_override_for(axn, :allowed_callers).nil?
      end

      # `required` is derived from the contract, not hardcoded true: a tool with no required inbound
      # fields — an ambient-context-only tool (empty input schema), or one whose inputs are all
      # optional — accepts a blank body (the router parses a blank body as `{}`), so forcing a body
      # would make OpenAPI validators and generated clients reject a request that succeeds at runtime.
      def request_body(input_schema, axn)
        schema = input_schema
        # When the adapter rejects unknown top-level fields at runtime (reject_undeclared_inputs),
        # reflect that in the published schema — otherwise OpenAPI validators / generated clients
        # accept or send a payload the mounted API will 400. Core leaves additionalProperties at JSON
        # Schema's permissive default; tighten it to match. `merge` returns a new Hash (never mutates
        # the core-owned input_schema). Top-level only — that's the scope of the runtime check.
        #
        # Resolved PER TOOL (the setting is `overridable:`), exactly as the Dispatcher resolves it, so a
        # tool that overrode it via `configure(:openapi)` is advertised the way it actually behaves.
        schema = schema.merge(additionalProperties: false) if Axn::OpenAPI.resolve_override_for(axn, :reject_undeclared_inputs)
        {
          "required" => Array(input_schema[:required]).any?,
          "content" => { "application/json" => media_type(schema, axn, :request_example) },
        }
      end

      def error_response(description)
        { "description" => description, "content" => { "application/json" => { "schema" => error_ref } } }
      end

      # Built FRESH per call (not shared frozen constants) so every generated document owns
      # independent, mutable error structures — a caller customizing one returned doc's error schema
      # can't contaminate later `.spec` results or already-served app documents through shared nested
      # hashes. (String values are frozen literals, so they're safely shareable; only the containers
      # need to be per-document.)
      def error_ref
        { "$ref" => "#/components/schemas/Error" }
      end

      def error_schema
        {
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
        }
      end
    end
  end
end
