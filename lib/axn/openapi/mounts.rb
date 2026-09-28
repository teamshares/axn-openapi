# frozen_string_literal: true

module Axn
  module OpenAPI
    # Which mount serves which tool, process-wide — so one tool can't quietly be served by two mounts
    # with different auth (a credentials tool reachable through a general-purpose mount is exactly the
    # leak named mounts exist to prevent). Keyed by mount name (`nil` = the default mount).
    #
    # Each claim remembers WHERE the mount was built: the chain of application frames that led to the
    # build (the routes file line, plus any helper of the app's own it went through), stopping at the
    # first frame inside a gem or Ruby itself. A rebuild through the same chain REPLACES the claim —
    # that is what Rails route reloading does — while building the same mount again through any other
    # chain raises: two live apps under one name would otherwise both serve its tools, each with its
    # own auth. The whole chain, not just the innermost frame, so a shared `build_credentials_app`
    # helper called from two places is two builds rather than one "reload". Tools are identified by
    # name, so a reloaded class still collides with its previous self's claim.
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

      # The application frames that built the app: skip this gem's own frames, then keep every frame
      # up to the first one inside an installed gem or Ruby's own library (actionpack's `draw`,
      # rspec, rack) — below that the stack differs between boot and a reload, so it can't be part of
      # the identity.
      def build_site
        frames = caller_locations.map { |location| [File.expand_path(location.path), location] }
                                 .drop_while { |path, _| path.start_with?(LIB_DIR) }
                                 .take_while { |path, location| !library_frame?(location.path, path) }
        return "(unknown)" if frames.empty?

        frames.map { |_, location| "#{location.path}:#{location.lineno}" }.join(" via ")
      end

      def library_frame?(raw_path, path)
        raw_path.start_with?("<internal:") || library_dirs.any? { |dir| path.start_with?(dir) }
      end

      def library_dirs
        @library_dirs ||= begin
          dirs = Gem.path + [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["rubyarchdir"]]
          dirs << Bundler.bundle_path.to_s if defined?(Bundler) && Bundler.respond_to?(:bundle_path)
          dirs.compact.map { |dir| File.join(File.expand_path(dir), "") }.uniq.freeze
        end
      end

      def identity(axn) = axn.name || axn.inspect
      def label(mount) = mount.nil? ? "the default mount" : "mount #{mount.inspect}"
    end
  end
end
