# frozen_string_literal: true

Rails.application.routes.draw do
  mount Axn::OpenAPI.app(auth: :none, tools: [EchoTool, GreeterV1, GreeterV2]) => "/api"
  mount Axn::OpenAPI.app(
    auth: CREDENTIALS_AUTH,
    mount: :credentials,
    tools: [IntegrationCredentials],
    context: ->(_env, principal) { { caller_id: principal } },
    info: { title: "Credentials API" },
  ) => "/internal/credentials"
  post "/loans/approve", to: "loans#approve"
  post "/loans/whoami", to: "loans#whoami"
  post "/credentials/read", to: "credentials#read"
end
