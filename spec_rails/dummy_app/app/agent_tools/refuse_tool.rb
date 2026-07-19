# frozen_string_literal: true

class RefuseTool
  include Axn

  tool :openapi
  description "Always refuses."
  expects :amount, type: Integer
  def call = fail!("Amount too large")
end
