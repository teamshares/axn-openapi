# frozen_string_literal: true

# A credentials tool kept OUT of app/agent_tools (the root axn-mcp/axn-ruby_llm also serve) and bound
# to the :credentials mount, so neither another mount nor another adapter can serve it.
class IntegrationCredentials
  include Axn

  tool openapi: {
    mount: :credentials,
    allowed_callers: ["data_pipeline"],
    operation_tags: ["Credentials"],
    request_example: { company_uuid: "c-1" },
    response_example: { company_uuid: "c-1", read_by: "data_pipeline", client_secret_ciphertext: "ciphertext-b64" },
  }
  description "Returns an integration's encrypted credentials."
  expects :company_uuid, type: String
  expects :caller_id, on: :ambient_context, type: String
  exposes :company_uuid, type: String
  exposes :read_by, type: String
  # axn logs exposures on every call; a credential exposure must be `sensitive:` so it's filtered.
  exposes :client_secret_ciphertext, type: String, sensitive: true

  tag :caller_id, :caller_id
  tag :company_uuid, :company_uuid

  def call = expose(company_uuid:, read_by: caller_id, client_secret_ciphertext: "ciphertext-b64")
end
