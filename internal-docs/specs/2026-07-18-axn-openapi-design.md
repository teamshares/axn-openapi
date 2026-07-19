# axn-openapi — v1 Design

**Ticket:** [PRO-2936](https://linear.app/teamshares/issue/PRO-2936/axn-axn-openapi)
**Status:** Design approved in brainstorming; ready for implementation planning.
**Date:** 2026-07-18

A new adapter in the "toolable" family (sibling of `axn-mcp` / `axn-ruby_llm`) that serves
Axns over HTTP as an OpenAPI-described JSON API. Give it a set of tools (Axns); it
auto-generates an OpenAPI 3.1 spec, routes inbound HTTP requests to the right Axn, runs it,
and returns JSON. Secondary value: the first non-LLM consumer of the toolable machinery, so it
stress-tests whether the core tool/reflection semantics generalize beyond MCP/LLM.

---

## Scope (v1)

Build the whole gem and release it as one functional unit (meaningful commits, not staged PRs).
All three skins ship in v1, over one shared core dispatcher:

1. **Core dispatcher** — transport-agnostic `dispatch(tool_name, params, context) → {status, body}`.
2. **Rack app / Rails engine** — `mount`able in routes; framework-agnostic (satisfies "works outside Rails").
3. **Controller mixin** — `include Axn::OpenAPI::Controller` + `render_axn(...)` for consumers who want
   their existing auth / filters / middleware stack.
4. **Spec generator** — assembles the OpenAPI document from reflection.

All skins read the same reflection surface and route through the same dispatcher — no parallel path.

**Explicitly out of v1:** content negotiation, auth beyond the `ambient_context` hook, HTTP
versioning (see "Versioning" below), YAML/Swagger-UI spec rendering.

---

## Reuse of existing machinery

The adapter adds no parallel path; it composes machinery that already exists:

| Concern | Existing machinery |
|---|---|
| Membership | `Axn.tools_for(:openapi)`; self-register via `register_tool_adapter(:openapi, self)` + `AdapterRoots` (`tool_roots`). Mount defaults to that list, also accepts an explicit array. |
| Tool identity | `tool_name` — already provider-safe `[a-z0-9_]`, hence URL-safe. |
| Contracts | `AnyAxn.input_schema` / `output_schema` (`axn/lib/axn/core/schema_reflection.rb`) — already JSON Schema, "the lingua franca of JSON Schema / OpenAPI / MCP." OpenAPI 3.1 uses JSON Schema 2020-12 natively, so spec assembly is near-mechanical. |
| Dispatch | `Axn::Tools::Invoker` (`axn/lib/axn/tools/invoker.rb`) — the sanctioned tool-run entry: strips reserved keys, injects trusted `ambient_context`, coercion on, returns an `Axn::Result`. |
| Auth / request context | `ambient_context` seam — already excluded from `input_schema`, so `current_user` / request context flow in without leaking into the tool contract. The gem does not own auth; it offers the hook. |
| Output serialization | `Axn::Reflection::Values.serialize_exposed` — the canonical, schema-aligned output serializer (same one `axn-mcp` uses). |
| HTTP-mapping precedent | `axn-webhooks` `Inbound::Endpoint#call(env)` — a `mount`able Rack app with a `Response` object (`.to_rack`) and a staged outcome→status mapper. Closest prior art. |

---

## Model: RPC-over-HTTP, not REST-resource

Axns are verbs/commands (`ApproveLoan`, `RecalculateBalance`), not nouns with a CRUD verb set.
So: **one endpoint per Axn**, RPC-style. Rejected alternatives: REST resources (impedance
mismatch), JSON:API (a document format for entities/relationships; Axn exposes aren't necessarily
entities), JSON-RPC 2.0 envelope (set aside in favor of plain HTTP+JSON where **HTTP status codes
carry meaning** — better for curl / frontends / OpenAPI tooling). JSON Schema *is* the contract
layer; OpenAPI is the generated artifact.

---

## Route shape

* **Flat, mount-rooted paths.** `POST /{tool_name}` per tool. The mount point is the prefix
  (`mount ... => "/api"` ⇒ `POST /api/approve_loan`).
* **Configurable `path_prefix`, default `""`** (flat). A consumer who wants tool routes visually
  namespaced can set it (`/api/axns/approve_loan`). No collision risk: `tool_name` is `[a-z0-9_]`
  (no dots), so it can never clash with the `.json` spec path, and verbs differ anyway.
* **Spec at `GET /openapi.json`** (configurable path), JSON only in v1.
* **All-POST in v1.** Even a read-only Axn can take a nested-object input, and querystring-encoding a
  nested JSON Schema is lossy/painful; a POST body is the only unambiguous carrier. `read_only → GET`
  is deferred (the signal is preserved — see below).
* **Per-operation metadata, mechanical from reflection:** `operationId = tool_name`;
  `summary` / `description` from the Axn's declared `description`.
* **Semantic hints as a vendor extension:** emit `x-axn-semantic-hints: [<read_only|idempotent|destructive>, ...]`
  (an array — plural, since `_semantic_hints` can hold more than one) in the operation object so the
  signal (from core `semantic_hints`) rides along in the doc at zero cost — the hook for a future
  `read_only → GET` mapping.
* **Routing edges:** unknown path → `404`, known tool path + wrong verb → `405`, `GET /openapi.json`
  → the spec.

---

## Response envelope

Asymmetric, following the grain of the contract:

* **Success (2xx): bare.** The body *is* the `output_schema` object — exposed keys at top level, no
  wrapper. `output_schema` describes it exactly, so the OpenAPI `responses` entry is literally
  `output_schema`. HTTP status already carries ok/not-ok (a top-level `ok: true` would just duplicate
  the status line — the JSON-RPC-envelope smell we rejected). Pagination metadata (`next_cursor`,
  etc.) lands naturally here as ordinary declared `exposes`.
* **Failure (4xx/5xx): a real envelope.** A failed Axn has no `output_schema` to honor (`exposes`
  aren't populated on failure), so failure needs its own declared shape — `{error: {message, ...}}`,
  a shared component in the spec. This asymmetry is principled, not inconsistent: success has a
  declared schema, failure doesn't, so only failure needs the gem to invent a shape.

---

## Serialization

* **Success body = `Axn::Reflection::Values.serialize_exposed`** (the same serializer `axn-mcp`
  uses). The body then matches `output_schema` **by construction** (they're co-designed:
  Symbol→String, Numeric→Float, Time→iso8601), and an Axn produces the identical JSON shape over MCP
  and HTTP. **Not** `ActiveJob::Arguments` — that's a round-trip serializer for async jobs (needs to
  reconstruct the *same Ruby object* later, which HTTP never does) and is both stricter (raises) and
  narrower (rejects plain POROs/Money/Structs that `serialize_value` handles via `to_h`/`as_json`).
* **Strict `Object#to_s` guard (config, default on).** `serialize_value`'s final fallback is
  `value.to_s`, which doesn't distinguish a meaningful custom `to_s` (e.g. Money → `"$4.00"`) from
  the default `Object#to_s` (`"#<User:0x…>"`). MCP tolerates the latter (output goes to an LLM); a
  published HTTP contract silently shipping `#<User:0x…>` — and having it "validate" because the
  field is untyped — is a contract bug, same family as `OutboundValidationError`. So: when an exposed
  value falls through to the **default** `Object#to_s` (no own `as_json`, no `to_h`, only inherited
  `to_s`) → treat as a **500** with a dev-facing message naming the field and the fix (declare
  `type: String` and format it, or give it `as_json`/`to_h`). A custom `to_s` passes through
  untouched. Configurable off for consumers who want MCP-identical leniency.

---

## Dispatch → HTTP status mapping

**Run tools through the shared `Invoker` with `user_facing_input_errors: true`.** This reclassifies
inbound validation failures into the *failure* bucket with a caller-safe message, exposes
`Invoker.input_invalid?(result)` as the sanctioned detector separating "caller sent bad data" from a
`fail!`, and correctly leaves an `ambient_context` validation failure dev-facing (our injected
context is trusted — if it's malformed that's a server bug, not the caller's) → 500.

Four-branch mapping:

```
result.ok?                      → 200  bare output_schema body
Invoker.input_invalid?(result)  → 400  envelope + field_errors   (InboundValidationError)
outcome.failure?  (a fail!)     → 422  envelope + message
else (outcome.exception?)       → 500  generic envelope, no leak  (already paged on_exception)
```

Plus the pre-dispatch HTTP-layer cases:

| Condition | Status |
|---|---|
| Body isn't parseable JSON | `400` |
| Path maps to no registered tool | `404` |
| Unsupported HTTP method on a known tool path | `405` |

### Status-code semantics (Scheme 1)

| Code | Meaning as used here |
|---|---|
| `200` | Success; body is the bare `output_schema` object |
| `400` | "Your request is malformed / you sent the wrong data" — unparseable JSON **and** `InboundValidationError` |
| `404` | Path maps to no registered tool |
| `405` | Known tool path, wrong HTTP verb |
| `422` | "We understood your well-formed request but can't complete the operation" — the `fail!` bucket |
| `500` | Unexpected exception; generic message, no internal leak |

**Deliberate departures worth documenting:**

* **Validation → 400, business `fail!` → 422** is intentional and semantically clean (400 = fix your
  request; 422 = request was fine, operation refused — 422's literal RFC 9110 meaning). It runs
  *against* the common Rails/FastAPI reflex of "422 = validation failed," so note it in the README so
  it doesn't read as an oversight. Chosen because no other coherent code pairing exists: 400 cannot
  describe a `fail!` (the request wasn't bad), so the only alternatives (409 for every `fail!`)
  misapply their meaning.
* **Validation → 400 keyed on `Invoker.input_invalid?`, independent of `user_facing:`.** This is what
  the ticket's "don't map onto `user_facing:`" principle actually requires: mapping on `outcome`
  alone would let `user_facing:` silently move the 400-vs-500 line (a non-user-facing
  `ValidationError` classifies as `exception`). Keying on the Invoker's detector keeps `user_facing:`
  governing message wording only, never the HTTP status. Cost: an inbound validation message
  (ActiveModel full messages like "Age must be an integer") is returned even when the author didn't
  opt into `user_facing:` — safe and standard, as it describes the caller's own input.
* **`fail!` message returned verbatim.** Consistent with the `sensitive:`-doesn't-mask-responses
  note: the author's `fail!("…")` is intentional and flows to the caller.

### `reject_undeclared_inputs`: config, default lenient

Extra unknown fields in the body are ignored by default (matches JSON Schema's own
`additionalProperties`-permitted posture; forward-compatible across client/server version skew; a
typo on a *required* field still fails validation → 400 regardless, so only optional-field typos are
silently dropped). Configurable to strict for consumers who want an exact contract.

---

## Versioning (v1: none built-in)

* **Model A is the default posture:** one live tool set; a breaking contract change breaks its
  clients (manage via additive evolution + coordination). `info.version` in the doc = the whole-API
  version (see below), unrelated to per-tool versioning.
* **Model B ("version-as-name," `approve_loan_v2`) is available for free** — a new version is just a
  new Axn with a new `tool_name`; nothing to build.
* **First-class versioning (Model C) is deferred to [PRO-2955](https://linear.app/teamshares/issue/PRO-2955)**
  (core: `version` as an attribute separate from `tool_name`; `(tool_name, version)` registry
  identity; path-routed HTTP versions with the bare path pinned to `default`). **Not a blocker for
  this gem** — the two are independent. v1's router is shaped so a future `/vN/` path segment is a
  clean insertion.
* **Locked durable sub-principle:** if HTTP versioning is ever added, it lives in the **path**, never
  as a scheme imposed on the cross-adapter `tool_name`.

### `info` config

The OpenAPI `info` object requires `title` and `version`. Provide a small configurable `info` block —
`title`, `version`, `description` — with sensible defaults (`title: "Axn API"`, `version:` defaulting
to `"1.0.0"` or the host/gem version, overridable).

---

## Pagination

The adapter is **agnostic** — it reflects whatever an Axn declares (`cursor`/`limit` in, `items`/
`next_cursor` out land naturally in the bare success body). A general-purpose **core** pagination
helper is appealing but is its **own ticket**, independent of and non-blocking for this gem; if built,
it belongs in the opt-in extras/strategy layer, not the base contract.

---

## Known reflection caveat to surface

`input_schema` warns and silently drops deep subfields nested under a `model:` / non-object parent
(they validate at runtime but have no JSON-object representation). The OpenAPI doc inherits this gap,
exactly as MCP does. Document it; consider surfacing the same warning at spec-generation time so a
consumer building tooling on the doc isn't misled.

---

## Component boundaries

* **`dispatch` core** — pure `(tool_name, params, context) → {status, body}`; no Rack/Rails
  knowledge. Owns the Invoker call + the four-branch status mapping + serialization + envelope. The
  one place error semantics live; all three skins delegate here.
* **Rack app / engine** — `env` → parse (JSON body, method, path) → `dispatch` → `Response#to_rack`.
  Mirrors `axn-webhooks` `Inbound::Endpoint`.
* **Controller mixin** — `render_axn(tool_or_name)` → `dispatch` → `render json:, status:`. The
  consumer's controller supplies auth/filters and builds `ambient_context`.
* **Spec generator** — `tools_for(:openapi)` (or explicit list) → assemble paths (one per tool),
  `requestBody` = `input_schema`, `responses` = `output_schema` + shared error component,
  `operationId`/`summary`/`description`/`x-axn-semantic-hints` from reflection → `info` block.
* **Response** — status + JSON body value object with `.to_rack`.
* **Config** (`Axn::Configurable`) — `path_prefix`, spec path, `reject_undeclared_inputs` (default
  false), strict-serialization guard (default true), `info` (title/version/description).
