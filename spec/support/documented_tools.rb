# frozen_string_literal: true

# Tools carrying the documentation-only settings (operation_tags, deprecated, examples). Like the
# versioned fixtures, they're NOT registered with :openapi (`configure`, not `tool openapi: {…}`), so
# they stay out of the global registry; specs pass them explicitly.
class TaggedTool
  include Axn

  axn_name "tagged"
  configure(:openapi) do |c|
    c.operation_tags = %w[Credentials Integrations]
    c.request_example = { company_uuid: "c-1", filters: { active: true } }
    c.response_example = { "integrations" => [{ "name" => "gusto" }] }
  end
  expects :company_uuid, type: String
  expects :filters, type: Hash, optional: true
  exposes :integrations, type: Array
  def call = expose(integrations: [])
end

class AlsoTaggedTool
  include Axn

  axn_name "also_tagged"
  configure(:openapi) { |c| c.operation_tags = ["Credentials"] }
  def call; end
end

# `deprecated` forced either way, against the auto rule (older versions of a tool are deprecated).
class PinnedV1Tool
  include Axn

  axn_name "pinned"
  tool_version 1
  configure(:openapi) { |c| c.deprecated = false }
  def call; end
end

class PinnedV2Tool
  include Axn

  axn_name "pinned"
  tool_version 2
  def call; end
end

class RetiredTool
  include Axn

  axn_name "retired"
  configure(:openapi) { |c| c.deprecated = true }
  def call; end
end

# A request_example that doesn't satisfy its own input schema (`n` must be an Integer).
class BadExampleTool
  include Axn

  axn_name "bad_example"
  configure(:openapi) { |c| c.request_example = { n: "not a number" } }
  expects :n, type: Integer
  def call; end
end
