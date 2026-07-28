# frozen_string_literal: true

# Two coexisting versions of one logical tool "calc", NOT registered with the :openapi adapter
# (no `tool :openapi`) so they don't leak into the global registry — unit specs pass them explicitly.
#
# NOTE: `tool_name` is a reader (it takes an optional `adapter` arg to consult a per-adapter
# override registered via `tool <adapter>: { name: }`), not a setter — a bare `tool_name :calc`
# statement computes and discards a value, it does not rename the tool. `axn_name "calc"` is the
# actual DSL for overriding the derived name without declaring `tool` (which would grant every
# adapter, defeating the point of keeping these fixtures unregistered). Verified against
# /Users/kali/code/core/axn/lib/axn/core/tools.rb and naming.rb.
class CalcV1Tool
  include Axn

  axn_name "calc"
  tool_version 1
  description "Returns the input."
  expects :n, type: Integer
  # `result` is a reserved exposure field name (Axn::Core::Contract::RESERVED_FIELD_NAMES_FOR_EXPOSURES) —
  # using it raises Axn::ContractViolation::ReservedAttributeError, so this fixture exposes `value` instead.
  exposes :value, type: Integer
  def call = expose(value: n)
end

class CalcV2Tool
  include Axn

  axn_name "calc"
  tool_version 2
  expects :n, type: Integer
  exposes :doubled, type: Integer
  def call = expose(doubled: n * 2)
end
