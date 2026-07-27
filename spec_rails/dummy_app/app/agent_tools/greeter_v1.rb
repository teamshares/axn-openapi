# frozen_string_literal: true

class GreeterV1
  include Axn

  tool :openapi
  axn_name "greeter"
  tool_version 1
  expects :subject, type: String
  exposes :greeting, type: String
  def call = expose(greeting: "hi #{subject}")
end
