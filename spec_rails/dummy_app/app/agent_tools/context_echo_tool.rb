# frozen_string_literal: true

class ContextEchoTool
  include Axn

  tool :openapi
  expects :actor, on: :ambient_context, type: String, allow_nil: true
  exposes :actor, type: String, allow_nil: true
  def call = expose(actor:)
end
