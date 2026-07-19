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
    setting :strict_serialization, default: true

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

    # Register :openapi with core's process-global registry, passing this module as the config
    # source so the registry reads Axn::OpenAPI.config.tool_roots for directory membership.
    Axn.register_tool_adapter(:openapi, self)
  end
end
