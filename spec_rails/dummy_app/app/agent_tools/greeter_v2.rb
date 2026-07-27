# frozen_string_literal: true

class GreeterV2
  include Axn

  tool :openapi
  axn_name "greeter"
  tool_version 2
  expects :subject, type: String
  exposes :greeting, type: String
  def call = expose(greeting: "Hello, #{subject}!")
end
