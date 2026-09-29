# frozen_string_literal: true

require "axn"
require "active_support/deprecation"

require_relative "openapi/version"

module Axn
  module OpenAPI
    extend Axn::Configurable
    extend Axn::Tools::AdapterRoots
    extend Axn::Tools::AdapterSerialization

    config_namespace :openapi

    # Route surface.
    setting :path_prefix, default: ""
    setting :spec_path, default: "/openapi.json"
    # How a tool_name is rendered as its URL path segment. `:snake` serves the tool_name as-is
    # (`/list_integrations/v1`); `:kebab` hyphenates it (`/list-integrations/v1`) for apps whose
    # route convention is kebab-case. Only the path changes — tool_name and operationId stay
    # snake_case, so generated clients and other adapters see the same names either way.
    setting :path_segment_style, default: :snake, one_of: %i[snake kebab]

    # Dispatch behavior.
    # `overridable` so a single strict endpoint can reject unknown body keys without imposing that on
    # every tool (and vice versa). Both readers — the Dispatcher's runtime check and SpecGenerator's
    # `additionalProperties` — must resolve it per-tool, or the published document would advertise a
    # posture the runtime doesn't enforce for an overriding tool.
    setting :reject_undeclared_inputs, default: false, one_of: [true, false], overridable: true

    # When true, serializing a successful result's `exposes` values rejects any value that has no JSON
    # rendering its author declared — one that would otherwise ship as an opaque blob like
    # `"#<User:0x...>"` (or, in Rails, ActiveSupport's generic instance-variable dump) — by raising
    # `Axn::Extensions::Serialization::UnserializableValue`, which the Dispatcher maps to a generic
    # 500. Default `true`, unlike axn-mcp's `false`: an LLM tool result can live with an
    # ugly-but-honest string, but a published HTTP contract shipping `#<…>` is a bug. Applies ONLY
    # to outbound `exposes` serialization, not to inbound argument handling. (Values with no
    # *honest* JSON form — cycles, non-finite Floats, non-UTF-8-encodable bytes, colliding property
    # names — raise regardless of this flag; it governs only the extra "was this rendering
    # author-declared?" check.)
    #
    # Named to match axn-mcp's identical knob, so one concept has one name across the adapter family.
    # `overridable` for the same reason: a single tool serving a legacy shape can opt out via
    # `configure(:openapi) { |c| c.reject_opaque_exposed_values = false }` without loosening the API.
    declare_reject_opaque_exposed_values! default: true

    # Which mount serves a tool. `nil` (the default) is the unnamed mount; a Symbol binds the tool to
    # `Axn::OpenAPI.app(mount: <that name>, …)` and keeps it OFF every other mount — declared on the
    # Axn itself (`tool openapi: { mount: :credentials }`) so the binding is visible where it matters.
    setting :mount, default: nil, overridable: true,
                    validate: ->(v) { v.nil? || v.is_a?(Symbol) || "mount must be a Symbol naming the mount (or nil for the default mount)" }

    # Principal ids allowed to call a tool (the 403 check); `nil` admits any authenticated caller.
    # Compared against the id a mount's auth strategy authenticated the request as (`Auth::Bearer`'s
    # key names, say). Empty is refused: an allowlist admitting nobody is a mistake, not a policy.
    setting :allowed_callers, default: nil, overridable: true,
                              validate: lambda { |v|
                                v.nil? ||
                                  (v.is_a?(Array) && v.any? && v.all? { |c| c.is_a?(String) || c.is_a?(Symbol) }) ||
                                  "allowed_callers must be a non-empty Array of principal ids (String/Symbol), or nil"
                              }

    # OpenAPI `info` object (title + version are required by the spec format).
    setting :info_title, default: "Axn API"
    setting :info_version, default: "1.0.0"
    setting :info_description, default: nil

    # Directory-root membership: an Axn under app/agent_tools/ is served without an explicit
    # `tool :openapi` — same default root as axn-mcp/axn-ruby_llm, so one tool serves everywhere.
    tool_roots_default %w[agent_tools]

    # This gem's error root. `include Axn::Error` (a marker module, so the StandardError ancestry is
    # untouched) puts it inside core's public-error boundary: one `rescue Axn::Error` catches axn's
    # own errors and this adapter's alike. The tag is inherited, so subclasses are covered too.
    class Error < StandardError
      include Axn::Error
    end

    def self.deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-openapi")
    end

    # Where an App stores the authenticated principal in the Rack env (nil under `auth: :none`).
    PRINCIPAL_ENV_KEY = "axn.openapi.principal"

    # The registered :openapi tool set (directory-root grants ∪ `tool :openapi` declarations) bound to
    # `mount` — the default (unnamed) mount serves only tools that name no mount, so a tool declaring
    # `tool openapi: { mount: :credentials }` never appears on it. Every declared version of each
    # tool — a stable HTTP contract serves each version at its own path, so callers must not be
    # limited to the latest-per-tool_name view.
    def self.tools(mount: nil)
      Axn::Tools.for(:openapi, all_versions: true).select { |axn| resolve_override_for(axn, :mount) == mount }
    end

    # A mountable Rack app. `auth:` is required — a strategy (`Axn::Extensions::Auth::Bearer`), an
    # Array of strategies (any may authenticate), or `:none`. `mount:` selects the tools bound to
    # that name (default: the unnamed mount); `tools:` serves an explicit list instead. See App.
    def self.app(auth: nil, mount: nil, tools: nil, authorize: nil, context: nil, public_spec: false, info: nil,
                 path_prefix: nil, spec_path: nil)
      App.new(auth:, mount:, tools:, authorize:, context:, public_spec:, info:, path_prefix:, spec_path:)
    end

    # The default 403 check: may `principal` call `axn_class`? A tool with no `allowed_callers` admits
    # any authenticated caller; otherwise the principal must be a String/Symbol id on the list.
    # Public so a custom `authorize:` callable can compose with it.
    def self.allowed_caller?(principal, axn_class)
      allowed = resolve_override_for(axn_class, :allowed_callers)
      return true if allowed.nil?
      return false unless principal.is_a?(String) || principal.is_a?(Symbol)

      allowed.any? { |id| id.to_s == principal.to_s }
    end

    # Pairs a strategy the gem can't describe on its own (a JWT verifier, say) with the OpenAPI
    # security scheme that documents it, so a mount can publish it in `components.securitySchemes`.
    def self.documented_auth(strategy, security_scheme:, name: "customAuth")
      Auth::Documented.new(strategy, security_scheme:, name:)
    end

    # The OpenAPI 3.1 document for the given tools (default: every registered :openapi tool).
    # `auth:` (optional here — nil documents no security) and `authorize:` shape the documented
    # security, exactly as they would for `.app`.
    def self.spec(mount: nil, tools: nil, auth: nil, authorize: nil, info: nil, path_prefix: nil)
      security_schemes = auth.nil? ? {} : Auth.security_schemes(Auth.strategies_for(auth))
      SpecGenerator.new(tools: tools || self.tools(mount:), path_prefix:, info:, security_schemes:,
                        authorize_all: !authorize.nil?).generate
    end

    # Register :openapi with core's process-global registry, passing this module as the config
    # source so the registry reads Axn::OpenAPI.config.tool_roots for directory membership.
    Axn::Tools.register_adapter(:openapi, self)
  end
end

require_relative "openapi/response"
require_relative "openapi/auth"
require_relative "openapi/dispatch"
require_relative "openapi/dispatcher"
require_relative "openapi/request"
require_relative "openapi/gate"
require_relative "openapi/route_table"
require_relative "openapi/router"
require_relative "openapi/app"
require_relative "openapi/controller"
require_relative "openapi/spec_generator"
