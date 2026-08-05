# frozen_string_literal: true

module Axn
  module OpenAPI
    # One entry per tool version: its served path, the Axn that answers it, and its doc-local
    # operationId. RouteEntry.path already includes the configured path_prefix.
    RouteEntry = Data.define(:path, :axn, :operation_id)

    # The single source of the tool→path map. Router builds its dispatch map from this and
    # SpecGenerator emits its paths from this, so served routes and documented paths can't diverge.
    # Every version is addressable at `{prefix}/{tool_name}/v{tool_version}` — no bare/default/latest.
    module RouteTable
      module_function

      # `tools` is the all-versions enumeration (Axn::Tools.for(:openapi, all_versions: true)) or any
      # explicit list. Deterministic order: by tool_name, then ascending tool_version.
      def build(tools:, path_prefix:)
        prefix = path_prefix.to_s
        tools
          .sort_by { |axn| [axn.tool_name(:openapi), axn.tool_version] }
          .map do |axn|
            name = axn.tool_name(:openapi)
            version = axn.tool_version
            RouteEntry.new(
              path: "#{prefix}/#{name}/v#{version}",
              axn:,
              operation_id: "#{name}_v#{version}",
            )
          end
      end
    end
  end
end
