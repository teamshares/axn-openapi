# frozen_string_literal: true

Rails.application.routes.draw do
  mount Axn::OpenAPI.app(tools: [EchoTool, GreeterV1, GreeterV2]) => "/api"
  post "/loans/approve", to: "loans#approve"
  post "/loans/whoami", to: "loans#whoami"
end
