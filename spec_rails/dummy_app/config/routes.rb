# frozen_string_literal: true

Rails.application.routes.draw do
  mount Axn::OpenAPI.app(tools: [EchoTool]) => "/api"
  post "/loans/approve", to: "loans#approve"
end
