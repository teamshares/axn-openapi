# frozen_string_literal: true

class LoansController < ActionController::API
  include Axn::OpenAPI::Controller

  def approve = render_axn(RefuseTool, ambient_context: { actor: request.headers["X-Actor"] })

  def whoami = render_axn(ContextEchoTool, ambient_context: { actor: request.headers["X-Actor"] })
end
