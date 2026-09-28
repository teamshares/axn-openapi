# frozen_string_literal: true

# The controller skin serving an allowlisted tool: the controller authenticates, and render_axn
# enforces the tool's allowed_callers against the principal it passes.
class CredentialsController < ActionController::API
  include Axn::OpenAPI::Controller

  def read
    caller_id = request.headers["X-Caller"]
    render_axn(IntegrationCredentials, principal: caller_id, ambient_context: { caller_id: })
  end
end
