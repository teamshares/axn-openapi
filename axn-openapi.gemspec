# frozen_string_literal: true

require_relative "lib/axn/openapi/version"

Gem::Specification.new do |spec|
  spec.name = "axn-openapi"
  spec.version = Axn::OpenAPI::VERSION
  spec.authors = ["Kali Donovan"]
  spec.email = ["kali@teamshares.com"]

  spec.summary = "axn-openapi: an axn-consuming gem."
  spec.description = "axn-openapi: an axn-consuming gem."
  spec.homepage = "https://github.com/teamshares/axn-openapi"
  spec.license = "MIT"

  # axn requires Ruby 3.2.1+ (Data.define, Vernier profiling).
  spec.required_ruby_version = ">= 3.2.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "https://github.com/teamshares/axn-openapi/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship the runtime payload only — allowlist, not denylist. A gem's shippable surface is small and
  # stable (lib/ + a few root docs), so enumerating it beats an ever-growing exclude list that
  # silently leaks new dev artifacts into the package. `git ls-files` keeps this to tracked files.
  # Anything not listed (bin/, spec*, docs/, internal-docs/, lefthook.yml, …) simply never ships;
  # add a token here only when you add a genuinely new shippable path (e.g. exe/ for a CLI).
  # AGENTS-consuming.md ships if you write one (agent-facing usage guide, read via `bundle show`);
  # `git ls-files` just omits it when absent, so it's a harmless no-op until then.
  spec.files = IO.popen(
    %w[git ls-files -z -- lib README.md CHANGELOG.md LICENSE.txt AGENTS-consuming.md],
    chdir: __dir__, err: IO::NULL,
  ) { |ls| ls.readlines("\x0", chomp: true) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Serializer passes `reject_opaque:` to Axn::Reflection::Values.serialize_exposed, which only accepts
  # it as of teamshares/axn#206. Pairing this gem with an older axn fails in the worst possible way
  # rather than at load: the unknown keyword raises ArgumentError inside Dispatcher.success, whose
  # `rescue StandardError` turns EVERY otherwise-successful dispatch into a generic 500. So the floor
  # must exclude any axn without it.
  #
  # #206 merged AFTER the alpha.5 release commit without a version bump, so `main` still reports
  # alpha.5 and no version number distinguishes the two. `>= alpha.5` is nonetheless exact in
  # practice: alpha.5 was never published to RubyGems (alpha.4.3 is the newest that was), so the only
  # things this admits are axn's git `main`, which has #206, and any future release, which will too.
  # Raise this to the next published version once axn cuts one, at which point it can be exact by
  # construction rather than by that accident.
  spec.add_dependency "axn", ">= 0.1.0-alpha.5", "< 0.2.0"
  spec.add_dependency "rack", ">= 2.2"
end
