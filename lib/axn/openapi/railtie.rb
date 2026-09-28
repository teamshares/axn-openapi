# frozen_string_literal: true

module Axn
  module OpenAPI
    # Ties the mount registry (Mounts) to Rails' route lifecycle: an app built while a route set is
    # drawn is claimed on that route set's behalf, and clearing the route set — every route reload
    # clears before it redraws — releases those claims. Without this, a reload after an edit that
    # moves a mount's line would look like a second live build of the mount and raise.
    module RouteSetClaims
      def clear!
        Mounts.release!(self)
        super
      end

      private

      def eval_block(block)
        Mounts.drawing(self) { super }
      end
    end

    class Railtie < ::Rails::Railtie
      initializer "axn_openapi.route_set_claims" do
        require "action_dispatch/routing/route_set"
        routes = ActionDispatch::Routing::RouteSet
        routes.prepend(RouteSetClaims) unless routes < RouteSetClaims
      end
    end
  end
end
