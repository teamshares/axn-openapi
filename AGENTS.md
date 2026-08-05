# AGENTS.md

Guidance for agents working on **axn-openapi**, an [axn](https://github.com/teamshares/axn)-consuming gem.

## Axn

Before writing or modifying an Axn action (`include Axn`): run `bundle show axn` and read
`AGENTS-consuming.md` there — the `expects`/`exposes`/`call` contract, failure surfaces
(`fail!`/`fails_on`/unhandled exception, `standalone:`/`join:`), and gotchas.

## Rules

- TDD: failing test first.
- Works outside Rails — guard `Rails`/`ActiveRecord`/`ActiveJob` references with `defined?(...)`.
- Before done: `bundle exec rake` runs the Rails-free specs + rubocop; run `bundle exec rake verify` to also run the Rails dummy-app suite (`spec_rails`) — required for any Rails-affecting change.
- `axn` comes from RubyGems, resolved by the gemspec constraint (`>= 0.1.0-alpha.5`, `< 0.2.0`) — no
  git pin. `Gemfile.lock` is gitignored and CI resolves fresh, so a new axn prerelease lands the
  moment it publishes; re-run tests after `bundle update axn`. When you need an unreleased axn
  change, prefer a temporary local override (`bundle config set --local local.axn <path>`, which
  needs a git source in the Gemfile) over committing a git pin, and raise the gemspec floor once the
  change ships.
- Working docs (planning specs/plans, design notes) go in `internal-docs/`. Reserve top-level
  `docs/` for user-facing documentation (a hosted site). The gem packages only `lib/` + root docs
  (README/CHANGELOG/LICENSE), so neither `internal-docs/` nor `docs/` ships — the README is the
  packaged doc.
- `bin/setup` installs a lefthook pre-commit hook (config in `lefthook.yml`) that runs RuboCop on
  staged Ruby files and blocks on offenses (check-only — no autocorrect, to avoid re-staging
  partially-staged files). `git commit --no-verify` skips it; CI runs the full `rake` regardless.

## Changes & compatibility

- CHANGELOG every public-facing change under `## Unreleased`, tagged `[FEAT]` / `[BREAKING]` /
  `[BUGFIX]` / `[INTERNAL]` — dense and specific (what changed, why, edge behavior). For
  `[BREAKING]`, state old vs new explicitly.
