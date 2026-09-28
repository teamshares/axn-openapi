# frozen_string_literal: true

# Tools bound to a named mount — served only by `Axn::OpenAPI.app(mount: :credentials, …)`, never by
# the default mount. Registered (process-global), so the default-mount facade specs double as proof
# that a named-mount tool stays off the default surface.
class CredentialsTool
  include Axn

  tool openapi: { mount: :credentials, allowed_callers: ["data_pipeline"] }
  description "Returns encrypted credentials."
  expects :company_uuid, type: String
  expects :caller_id, on: :ambient_context, type: String, allow_nil: true
  exposes :company_uuid, type: String
  exposes :caller_id, type: String, allow_nil: true
  def call = expose(company_uuid:, caller_id:)
end

# A second credentials-mount tool with no allowlist: any authenticated caller may use it.
class CredentialsPingTool
  include Axn

  tool openapi: { mount: :credentials }
  exposes :pong, type: String
  def call = expose(pong: "pong")
end
