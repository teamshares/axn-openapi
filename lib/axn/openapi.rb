# frozen_string_literal: true

require "axn"
require "active_support/deprecation"

require_relative "openapi/version"

module Axn
  module OpenAPI
    extend Axn::Configurable
    extend Axn::Tools::AdapterRoots

    config_namespace :openapi

    # Route surface.
    setting :path_prefix, default: ""
    setting :spec_path, default: "/openapi.json"

    # Dispatch behavior.
    setting :reject_undeclared_inputs, default: false

    # Rejects an exposed value that would render honestly but unpresentably — one whose only `to_s`
    # is the inherited Object#to_s, or whose only `as_json` is ActiveSupport's generic ivar dump. A
    # published HTTP contract must not ship `"#<User:0x…>"`. Values that cannot be rendered as JSON
    # at all (cycles, colliding property names, non-finite Floats, non-UTF-8 bytes) are rejected by
    # core unconditionally and are not affected by this setting.
    setting :reject_opaque, default: true

    # OpenAPI `info` object (title + version are required by the spec format).
    setting :info_title, default: "Axn API"
    setting :info_version, default: "1.0.0"
    setting :info_description, default: nil

    # Directory-root membership: an Axn under app/agent_tools/ is served without an explicit
    # `tool :openapi` — same default root as axn-mcp/axn-ruby_llm, so one tool serves everywhere.
    setting :tool_roots, default: %w[agent_tools], validate: ->(v) { Axn::Tools::AdapterRoots.validate!(v) }

    class Error < StandardError; end

    def self.deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-openapi")
    end

    # The registered :openapi tool set (directory-root grants ∪ `tool :openapi` declarations),
    # every declared version of each tool — a stable HTTP contract serves each version at its own
    # path, so callers must not be limited to the latest-per-tool_name view.
    def self.tools
      Axn.tools_for(:openapi, all_versions: true)
    end

    # A mountable Rack app over the given tools (default: every registered :openapi tool).
    def self.app(tools: nil, context: nil, path_prefix: nil, spec_path: nil)
      App.new(tools: tools || self.tools, context:, path_prefix:, spec_path:)
    end

    # The OpenAPI 3.1 document for the given tools (default: every registered :openapi tool).
    def self.spec(tools: nil, path_prefix: nil, info: nil)
      SpecGenerator.new(tools: tools || self.tools, path_prefix:, info:).generate
    end

    # Register :openapi with core's process-global registry, passing this module as the config
    # source so the registry reads Axn::OpenAPI.config.tool_roots for directory membership.
    Axn.register_tool_adapter(:openapi, self)
  end
end

require_relative "openapi/response"
require_relative "openapi/serializer"
require_relative "openapi/dispatch"
require_relative "openapi/dispatcher"
require_relative "openapi/request"
require_relative "openapi/route_table"
require_relative "openapi/router"
require_relative "openapi/app"
require_relative "openapi/controller"
require_relative "openapi/spec_generator"
