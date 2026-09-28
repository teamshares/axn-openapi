# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in axn-openapi.gemspec
gemspec

gem "lefthook", "~> 2.0" # Git-hook manager (pre-commit RuboCop on staged files)
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop", "~> 1.21"

# Validates generated documents against the OpenAPI 3.1 metaschema in the suite.
gem "json_schemer", "~> 2.4"

# TEMP (PRO-3566): unreleased Axn::Extensions::Auth. Resolved via
# `bundle config set --local local.axn <axn worktree>`; drop once the axn prerelease ships.
gem "axn", git: "https://github.com/teamshares/axn", branch: "kali/pro-3566-shared-request-auth"
