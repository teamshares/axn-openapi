# frozen_string_literal: true

module Axn
  module OpenAPI
    # A mount's `auth:` — normalized to a list of strategies (tried in order, first to authenticate
    # wins), plus the OpenAPI-specific reading of them. The strategies themselves are axn core's
    # (`Axn::Extensions::Auth`, e.g. `Auth::Bearer`) or anything honoring that protocol; core knows
    # nothing about OpenAPI, so mapping a strategy onto a `securitySchemes` entry lives here.
    module Auth
      NONE = :none

      module_function

      # Fail-closed: a mount must say how it authenticates. `:none` is the explicit opt-out.
      def strategies_for(auth)
        if auth.nil?
          raise Axn::OpenAPI::Error,
                "auth: is required — pass a strategy (e.g. Axn::Extensions::Auth::Bearer.new(keys: {...})), " \
                "an Array of strategies (any may authenticate), or auth: :none to serve unauthenticated"
        end
        return [] if auth == NONE

        list = auth.is_a?(Array) ? auth : [auth]
        raise Axn::OpenAPI::Error, "auth: must list at least one strategy (or be :none)" if list.empty?

        list.each do |strategy|
          next if strategy.respond_to?(:call)

          raise Axn::OpenAPI::Error,
                "auth: strategies must respond to #call(request) (got #{strategy.class}); :none cannot be combined with strategies"
        end
        list.dup.freeze
      end

      # `components.securitySchemes`, name => scheme, in strategy order. Raises at build time for a
      # strategy that doesn't describe itself, so the published document can't silently omit how a
      # mount actually authenticates.
      def security_schemes(strategies)
        strategies.each_with_object({}) do |strategy, schemes|
          name, scheme = scheme_for(strategy)
          name = "#{name}#{2.step.find { |n| !schemes.key?("#{name}#{n}") }}" if schemes.key?(name)
          schemes[name] = scheme
        end
      end

      # Every strategy's 401 challenge, merged — same-named headers joined, per RFC 9110's
      # comma-separated `WWW-Authenticate` list.
      def unauthorized_headers(strategies)
        strategies.each_with_object({}) do |strategy, headers|
          next unless strategy.respond_to?(:unauthorized_headers)

          (strategy.unauthorized_headers || {}).each do |key, value|
            key = key.to_s.downcase
            headers[key] = headers.key?(key) ? "#{headers[key]}, #{value}" : value
          end
        end
      end

      # The principal ids the strategies can authenticate as, or nil when any strategy can't say
      # (a JWT verifier admits whoever holds a valid token) — nil means "don't check allowlists
      # against it at boot", never "admits nobody".
      def known_principals(strategies)
        ids = strategies.map { |strategy| strategy.respond_to?(:principals) ? strategy.principals : nil }
        return nil if ids.any?(&:nil?)

        ids.flatten.map(&:to_s).uniq
      end

      def scheme_for(strategy)
        if strategy.respond_to?(:openapi_security_scheme)
          name = strategy.respond_to?(:openapi_security_scheme_name) ? strategy.openapi_security_scheme_name : nil
          [(name || "customAuth").to_s, deep_stringify(strategy.openapi_security_scheme)]
        elsif strategy.respond_to?(:scheme) && strategy.scheme.to_s.casecmp?("bearer")
          ["bearerAuth", { "type" => "http", "scheme" => "bearer" }]
        elsif strategy.respond_to?(:header) && strategy.header
          ["apiKeyAuth", { "type" => "apiKey", "in" => "header", "name" => strategy.header.to_s }]
        else
          raise Axn::OpenAPI::Error,
                "can't describe auth strategy #{strategy.class} in the OpenAPI document; wrap it with " \
                "Axn::OpenAPI.documented_auth(strategy, security_scheme: { type: \"http\", scheme: \"bearer\", bearerFormat: \"JWT\" })"
        end
      end

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
        when Array then value.map { |v| deep_stringify(v) }
        else value
        end
      end

      # A strategy paired with the OpenAPI security scheme that describes it — for a strategy core
      # can't describe neutrally, such as a JWT verifier written in the consuming app. Delegates
      # authentication and the optional protocol metadata to the wrapped strategy.
      class Documented
        attr_reader :openapi_security_scheme, :openapi_security_scheme_name

        def initialize(strategy, security_scheme:, name: "customAuth")
          raise Axn::OpenAPI::Error, "documented_auth strategy must respond to #call(request) (got #{strategy.class})" unless strategy.respond_to?(:call)

          scheme = Auth.deep_stringify(security_scheme)
          raise Axn::OpenAPI::Error, "documented_auth security_scheme must be a Hash with a \"type\"" unless scheme.is_a?(Hash) && scheme["type"]

          @strategy = strategy
          @openapi_security_scheme = scheme.freeze
          @openapi_security_scheme_name = name.to_s
        end

        def call(request) = @strategy.call(request)
        def principals = @strategy.respond_to?(:principals) ? @strategy.principals : nil

        # The wrapped strategy's own challenge when it gives one; otherwise, for an `http` scheme, the
        # challenge that scheme implies (`WWW-Authenticate: Bearer`), since RFC 9110 requires a 401 to
        # carry one. Other scheme types (apiKey, oauth2, …) have no standard challenge to derive.
        def unauthorized_headers
          own = @strategy.respond_to?(:unauthorized_headers) ? @strategy.unauthorized_headers : nil
          return own if own && !own.empty?

          scheme = openapi_security_scheme["scheme"].to_s
          return {} unless openapi_security_scheme["type"] == "http" && !scheme.empty?

          { "www-authenticate" => scheme[0].upcase + scheme[1..] }
        end

        # The wrapped strategy may close over live credentials: never render it.
        def inspect = "#<#{self.class.name} name=#{openapi_security_scheme_name.inspect} strategy=[REDACTED]>"
        def pretty_print(printer) = printer.text(inspect)
      end
    end
  end
end
