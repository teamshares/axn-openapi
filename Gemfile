# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in axn-openapi.gemspec
gemspec

# Temporary: track axn's main branch until the features this gem relies on ship in a released
# version. Flip back to the released gem (drop this line) once that lands.
#
# Requires axn > 0.1.0-alpha.5 (teamshares/axn#206): the serializer delegates every "no honest JSON
# representation" rejection to Axn::Reflection::Values.serialize_exposed(reject_opaque:).
gem "axn", github: "teamshares/axn", branch: "main"

gem "lefthook", "~> 2.0" # Git-hook manager (pre-commit RuboCop on staged files)
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop", "~> 1.21"
