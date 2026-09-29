# frozen_string_literal: true

module Axn
  module OpenAPI
    # One entry per tool version: its served path, the Axn that answers it, and its doc-local
    # operationId. RouteEntry.path already includes the configured path_prefix.
    # `segment` is the tool's rendered path segment (see `path_segment_style`) — what a 404 names.
    RouteEntry = Data.define(:path, :axn, :operation_id, :segment)

    # The single source of the tool→path map. Router builds its dispatch map from this and
    # SpecGenerator emits its paths from this, so served routes and documented paths can't diverge.
    # Every version is addressable at `{prefix}/{tool_name}/v{tool_version}` — no bare/default/latest.
    module RouteTable
      module_function

      # `tools` is the all-versions enumeration (Axn::Tools.for(:openapi, all_versions: true)) or any
      # explicit list. Deterministic order: by tool_name, then ascending tool_version.
      def build(tools:, path_prefix:, path_segment_style: Axn::OpenAPI.config.path_segment_style)
        prefix = path_prefix.to_s
        tools
          .sort_by { |axn| [axn.tool_name(:openapi), axn.tool_version] }
          .map do |axn|
            segment = segment_for(axn, path_segment_style)
            RouteEntry.new(path: "#{prefix}/#{segment}/v#{axn.tool_version}", axn:, operation_id: operation_id(axn), segment:)
          end
      end

      def segment_for(axn, style)
        name = axn.tool_name(:openapi)
        style == :kebab ? name.tr("_", "-") : name
      end

      # The doc-local operationId for one tool version — also what the gate tags a request with.
      def operation_id(axn) = "#{axn.tool_name(:openapi)}_v#{axn.tool_version}"
    end
  end
end
