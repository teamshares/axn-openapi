# frozen_string_literal: true

module Axn
  module OpenAPI
    # The transport-agnostic result of running a tool: an HTTP status + a JSON-ready body Hash.
    # Every skin (Rack app, controller mixin) renders this the same way.
    Dispatch = Data.define(:status, :body)
  end
end
