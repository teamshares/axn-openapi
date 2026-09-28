# frozen_string_literal: true

module Axn
  module OpenAPI
    # Which mount serves which tool, process-wide — so one tool can't quietly be served by two mounts
    # with different auth (a credentials tool reachable through a general-purpose mount is exactly the
    # leak named mounts exist to prevent). Keyed by mount name (`nil` = the default mount).
    #
    # Each claim remembers WHERE the mount was built (the caller's file:line). A rebuild from the same
    # site REPLACES the claim — that is what Rails route reloading does — while building the same
    # mount again from anywhere else raises: two live apps under one name would otherwise both serve
    # its tools, each with its own auth. Tools are identified by name, so a reloaded class still
    # collides with its previous self's claim.
    module Mounts
      Claim = Data.define(:site, :tools)

      LIB_DIR = File.expand_path("..", __dir__)
      private_constant :LIB_DIR

      @claims = {}
      @lock = Mutex.new

      module_function

      def claim!(mount, tools, site:)
        ids = tools.to_h { |axn| [identity(axn), axn] }
        @lock.synchronize do
          existing = @claims[mount]
          if existing && existing.site != site
            raise Axn::OpenAPI::Error,
                  "#{label(mount).capitalize} is already built at #{existing.site}; building it again at #{site} " \
                  "would leave two live apps serving its tools. Build each mount once (give an ad-hoc mount its own mount: name)"
          end

          @claims.each do |other, claim|
            next if other == mount

            shared = claim.tools.keys & ids.keys
            next if shared.empty?

            raise Axn::OpenAPI::Error,
                  "#{shared.first} is already served by #{label(other)}; building #{label(mount)} would serve it " \
                  "from two mounts. Bind it to one with `tool openapi: { mount: ... }`, or drop it from one mount's tools:"
          end
          @claims[mount] = Claim.new(site:, tools: ids.freeze)
        end
      end

      def reset! = @lock.synchronize { @claims = {} }

      # The first frame outside this gem — the routes file (or spec) that built the app.
      def build_site
        frame = caller_locations.find { |location| !File.expand_path(location.path).start_with?(LIB_DIR) }
        frame ? "#{frame.path}:#{frame.lineno}" : "(unknown)"
      end

      def identity(axn) = axn.name || axn.inspect
      def label(mount) = mount.nil? ? "the default mount" : "mount #{mount.inspect}"
    end
  end
end
