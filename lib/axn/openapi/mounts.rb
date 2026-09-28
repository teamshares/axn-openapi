# frozen_string_literal: true

module Axn
  module OpenAPI
    # Which mount serves which tool, process-wide — so one tool can't quietly be served by two mounts
    # with different auth (a credentials tool reachable through a general-purpose mount is exactly the
    # leak named mounts exist to prevent). Keyed by mount name (`nil` = the default mount); a rebuild
    # under the same key REPLACES that mount's claim, which is what Rails route reloading does. Tools
    # are identified by name, so a reloaded class still collides with its previous self's claim.
    module Mounts
      @claims = {}
      @lock = Mutex.new

      module_function

      def claim!(mount, tools)
        ids = tools.to_h { |axn| [identity(axn), axn] }
        @lock.synchronize do
          @claims.each do |other, claimed|
            next if other == mount

            shared = claimed.keys & ids.keys
            next if shared.empty?

            raise Axn::OpenAPI::Error,
                  "#{shared.first} is already served by #{label(other)}; building #{label(mount)} would serve it " \
                  "from two mounts. Bind it to one with `tool openapi: { mount: ... }`, or drop it from one mount's tools:"
          end
          @claims[mount] = ids.freeze
        end
      end

      def reset! = @lock.synchronize { @claims = {} }

      def identity(axn) = axn.name || axn.inspect
      def label(mount) = mount.nil? ? "the default mount" : "mount #{mount.inspect}"
    end
  end
end
