# frozen_string_literal: true

# A record class for a `model:` field. Its id is an opaque String whose lookup JSON Schema can't
# express, so core reports a residue on it.
class ResidueWidget
  def self.find(_id) = new
end

# Inputs whose constraints JSON Schema can't express exactly, so core renders them as residue prose
# in the property descriptions: a gated `length:`, a case-insensitive `format:` on a nullable field,
# a gated `numericality:` nested under a subfield, and a `model:` id.
class ResidueTool
  include Axn

  tool :openapi
  expects :mode, type: String, inclusion: { in: %w[strict loose] }
  expects :code, type: String, length: { maximum: 8 }, if: -> { mode == "strict" }
  expects :slug, type: String, allow_nil: true, format: { with: /\A[a-z]+\z/i }
  expects :meta, type: Hash
  expects :count, on: :meta, type: Integer, numericality: { greater_than: 0 }, if: -> { mode == "strict" }
  expects :widget, model: ResidueWidget
  def call; end
end
