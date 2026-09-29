# frozen_string_literal: true

# A two-word tool name (`list_integrations`), for the path_segment_style specs. Deliberately not
# registered for :openapi, so it only appears where a spec passes it explicitly.
class ListIntegrationsTool
  include Axn

  axn_name "list_integrations"
  exposes :count, type: Integer
  def call = expose(count: 2)
end
