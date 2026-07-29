# axn-openapi — agent guide

For an LLM writing code that **exposes** Axn actions over HTTP with this gem (not modifying the
gem's internals). Covers how to serve a tool, the status map, `ambient_context` for auth, and the
config knobs. On an edge case, read the source — paths below, via `bundle show axn-openapi`. Before
declaring `expects`/`exposes`/`fail!` on the Axn itself, read axn core's own `AGENTS-consuming.md`
(`bundle show axn`) — this gem adds no new authoring surface on the Axn side.

## Mental model

A plain Axn (`include Axn`) stays plain — no HTTP awareness. This gem turns it into an HTTP
endpoint at the edge, two ways:

- **`Axn::OpenAPI.app(**opts) → App`** — a mountable Rack app that owns routing: one
  `POST /<tool_name>/v<n>` per registered tool *version*, plus `GET /openapi.json` serving the
  generated spec.
- **`include Axn::OpenAPI::Controller`** — a mixin for a Rails (or any duck-typed
  `request`/`render`) controller that owns its own routing; `render_axn(axn_class, ambient_context:
  {})` does the run + render.

Both skins delegate to the same `Axn::OpenAPI::Dispatcher` — status/envelope behavior is identical
regardless of which one you use. There is no third path.

## Exposing a tool

Mark the Axn with `tool :openapi` (or drop it under a `tool_roots` directory — default
`app/agent_tools/` — to get membership with no declaration):

```ruby
class ApproveLoan
  include Axn
  tool :openapi

  expects :loan_id, type: Integer
  exposes :status, type: String

  def call
    loan = Loan.find(loan_id)
    fail!("Loan already decided") unless loan.pending?

    loan.approve!
    expose status: "approved"
  end
end
```

Mount every registered tool at once:

```ruby
# config/routes.rb
mount Axn::OpenAPI.app => "/api"   # ApproveLoan → POST /api/approve_loan/v1
```

`Axn::OpenAPI.app(tools: nil, context: nil, path_prefix: nil, spec_path: nil)` — `tools:` defaults
to `Axn::OpenAPI.tools` (`Axn.tools_for(:openapi, all_versions: true)`, i.e. every version of every
registered tool); pass an explicit array to serve a curated subset instead. **The mount point is the path prefix** — `mount ... =>
"/api"` puts every tool under `/api/...` and the spec at `/api/openapi.json`.

Every path is `{mount}{path_prefix}/{tool}/v{n}`, where `n` is the Axn's `tool_version` (undeclared
⇒ `1`). There is no bare, default, or "latest" path — the newest version is whatever `vN` is
highest in the served spec's `paths`, not a magic route. Declaring `tool_version N` on a second Axn
that shares a `tool_name` (set explicitly via `axn_name`, since distinct classes otherwise derive
distinct names) adds a `/vN` path alongside the existing ones — it never touches or replaces the
paths already registered for that tool's other versions. A `POST` to a known tool at an
unregistered version 404s with a message pointing at the latest available version's path.

Or own routing yourself:

```ruby
class LoansController < ApplicationController
  include Axn::OpenAPI::Controller

  def approve = render_axn(ApproveLoan, ambient_context: { approver_id: current_user.id })
end
```

## `ambient_context`: the auth seam

The gem does not authenticate requests itself — it offers a hook. `ambient_context` is a Hash of
trusted, request-derived values (current user id, request id, ...) that the Axn reads via
`expects ..., on: :ambient_context`. You build it *after* your own auth/session logic has already
run:

```ruby
# Mount skin: resolved per-request from the Rack env
Axn::OpenAPI.app(context: ->(env) { { approver_id: env["rack.session"]["user_id"] } })

# Controller skin: built inline from the controller's own auth
render_axn(ApproveLoan, ambient_context: { approver_id: current_user.id })
```

`ambient_context` fields never appear in the generated `input_schema`/`requestBody` — they're not
something the HTTP caller supplies. If the context you build is itself malformed, that's a **server
bug** (500), not a caller error (400) — the injected context is trusted.

## Status map (memorize this — it inverts the common Rails reflex)

| Code | Cause | Body |
| --- | --- | --- |
| `200` | Success | Bare `output_schema` object — no wrapper |
| `400` | Malformed JSON body, or a caller input-contract violation (`InboundValidationError`) | `{"error": {"message", "field_errors"}}` |
| `404` | No tool at that path, **or** a known tool at an unregistered version — message names the latest available version's path (mount skin only) | `{"error": {"message"}}` |
| `405` | Wrong HTTP verb — every tool route is `POST` (mount skin only) | `{"error": {"message"}}` |
| `422` | The Axn ran and called `fail!` — a well-formed request the operation refused | `{"error": {"message": "<fail! text, verbatim>"}}` |
| `500` | Unexpected exception, or an exposed value with no honest JSON representation (see `reject_opaque_exposed_values`) | `{"error": {"message": "Internal Server Error"}}` (generic, no leak) |

**`fail!` is 422, not 400.** This is deliberate: 400 means "your request was bad" (bad JSON, a
missing/mistyped field); 422 means "your request was fine, but we couldn't do it" — the literal
RFC 9110 meaning, and the only code that fits a business refusal. Don't "fix" this by routing
`fail!` to 400 — it's the documented design, not a bug.

Success is bare (`{"status": "approved"}`); failure is always the `{"error": {...}}` envelope —
never the reverse.

## Config knobs (`Axn::OpenAPI.config.<setting> = ...`)

| Setting | Default | Effect |
| --- | --- | --- |
| `path_prefix` | `""` | Prefix used when computing spec paths / matching requests (mount skin). |
| `spec_path` | `"/openapi.json"` | Where the mount skin serves the spec. |
| `reject_undeclared_inputs` | `false` | `true` → an unknown body key is a 400 and the published request schema sets `additionalProperties: false`; `false` → silently ignored. |
| `reject_opaque_exposed_values` | `true` | `true` → an exposed value that declares no JSON projection of its own is a 500 instead of rendering an object address (or, in Rails, ActiveSupport's generic `as_json` ivar dump). Does not govern values with no JSON rendering *at all* — a cycle, keys that collapse to one property, a non-finite `Float`, non-UTF-8 bytes — which axn core rejects unconditionally. |
| `info_title` / `info_version` / `info_description` | `"Axn API"` / `"1.0.0"` / `nil` | OpenAPI `info` block. |
| `tool_roots` | `%w[agent_tools]` | Directories granting implicit `:openapi` membership. |

Both behavioral knobs (`reject_undeclared_inputs`, `reject_opaque_exposed_values`) are **also settable
per tool** via `configure(:openapi) { |c| ... }` on the Axn; the per-class value wins over the gem-wide
one. A `reject_undeclared_inputs` override is reflected in the generated document too (that tool's
request schema alone gets `additionalProperties: false`), so the spec always matches what the endpoint
enforces. The other settings are gem-wide only.

## Generating the spec without mounting anything

```ruby
Axn::OpenAPI.spec(tools: nil, path_prefix: nil, info: nil) # => Hash, the OpenAPI 3.1 document
```

## Pointers

- `lib/axn/openapi.rb` — config + the `.app`/`.spec`/`.tools` facade.
- `lib/axn/openapi/dispatcher.rb` — the one place status/envelope semantics live; both skins
  delegate here.
- `lib/axn/openapi/router.rb` — the mount skin's HTTP-layer routing (404/405/400-parse).
- `lib/axn/openapi/spec_generator.rb` — OpenAPI 3.1 assembly from reflection.
- `internal-docs/specs/2026-07-18-axn-openapi-design.md` — the full design rationale (not shipped
  with the gem; read from a checkout).
