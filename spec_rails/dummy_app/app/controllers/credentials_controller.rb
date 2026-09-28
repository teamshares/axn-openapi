# frozen_string_literal: true

# The controller skin serving a mount-bound, allowlisted tool. The controller authenticates with the
# same strategy the :credentials mount uses; render_axn then enforces the tool's allowed_callers
# against the principal that authentication produced (never a caller-asserted header).
class CredentialsController < ActionController::API
  include Axn::OpenAPI::Controller

  def read
    verdict = Axn::Extensions::Auth.normalize(CREDENTIALS_AUTH.call(Axn::OpenAPI::Request.from_rack(request.env)))
    return head(:unauthorized) unless verdict.ok?

    render_axn(IntegrationCredentials, mount: :credentials, principal: verdict.principal,
                                       ambient_context: { caller_id: verdict.principal })
  end
end
