# frozen_string_literal: true

class EchoTool
  include Axn

  tool :openapi
  description "Echoes a message back."
  expects :message, type: String
  exposes :echoed, type: String
  def call = expose(echoed: message)
end
