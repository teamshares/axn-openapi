# frozen_string_literal: true

# A credentials tool kept OUT of app/agent_tools (the root axn-mcp/axn-ruby_llm also serve) and bound
# to the :credentials mount, so neither another mount nor another adapter can serve it.
class IntegrationCredentials
  include Axn

  tool openapi: { mount: :credentials, allowed_callers: ["data_pipeline"] }
  description "Returns an integration's encrypted credentials."
  expects :company_uuid, type: String
  expects :caller_id, on: :ambient_context, type: String
  exposes :company_uuid, type: String
  exposes :read_by, type: String

  tag :caller_id, :caller_id
  tag :company_uuid, :company_uuid

  def call = expose(company_uuid:, read_by: caller_id)
end
