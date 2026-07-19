# frozen_string_literal: true

require "axn"
require "active_support/deprecation"

require_relative "openapi/version"

module Axn
  module Openapi
    extend Axn::Configurable

    # Per-gem config namespace (Axn::Configurable, PRO-2880). Set globally with
    # `Axn::Openapi.configure { |c| c.enabled = false }`; read via `Axn::Openapi.config.enabled`
    # (and the generated `enabled?` predicate). The namespace keeps these settings from colliding
    # with another adapter's `configure(:...)` bag on the same action.
    config_namespace :openapi

    # Starter setting — replace with your gem's own. Add `overridable: true` to let a consuming Axn
    # set it per-class via `configure(:openapi) { |c| c.enabled = false }` (read back with
    # `Axn::Openapi.resolve_override_for(axn_class, :enabled)`); `callable: true` for a lambda default.
    setting :enabled, default: true

    class Error < StandardError; end

    # A dedicated deprecator instance, so a consuming Rails app can register it
    # (Rails.application.deprecators[:openapi] = Axn::Openapi.deprecator) and govern
    # its behavior (silence in test, raise in CI, etc.).
    def self.deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-openapi")
    end
  end
end
