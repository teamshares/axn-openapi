# frozen_string_literal: true

# A happy-path tool with a nested-object output and a semantic hint.
class EchoTool
  include Axn

  tool :openapi
  semantic_hints :read_only
  description "Echoes a message back."
  expects :message, type: String
  exposes :echoed, type: String
  def call = expose(echoed: message)
end

# A tool that fails a business rule via fail!.
class RefuseTool
  include Axn

  tool :openapi
  description "Always refuses."
  expects :amount, type: Integer
  def call = fail!("Amount too large")
end

# A tool whose call raises an unexpected exception.
class BoomTool
  include Axn

  tool :openapi
  expects :x, type: Integer
  def call = raise "kaboom"
end

# A tool that exposes an object with only the default Object#to_s (unserializable).
class OpaqueValue # rubocop:disable Lint/EmptyClass -- intentionally opaque: no attrs, no #to_h.
end

class OpaqueTool
  include Axn

  tool :openapi
  exposes :thing
  def call = expose(thing: OpaqueValue.new)
end

# Reads a value from ambient_context (the auth/request-context seam) and echoes it.
class ContextEchoTool
  include Axn

  tool :openapi
  expects :actor, on: :ambient_context, type: String, allow_nil: true
  exposes :actor, type: String, allow_nil: true
  def call = expose(actor:)
end
