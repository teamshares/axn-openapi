# frozen_string_literal: true

module Axn
  module OpenAPI
    # The transport-agnostic result of running a tool: an HTTP status, a JSON-ready body Hash, and
    # optional extra response headers (e.g. `Allow` on a 405). Every skin renders this the same way.
    Dispatch = Data.define(:status, :body, :headers) do
      # `headers` defaults to none. Data's `.new` normalizes positional args to keywords before
      # calling initialize, so a keyword-with-default initialize keeps BOTH existing 2-arg positional
      # construction (`Dispatch.new(status, body)`) and keyword construction working; only responses
      # that need extra headers (e.g. `Allow` on a 405) pass a third arg.
      def initialize(status:, body:, headers: {}) = super
    end
  end
end
