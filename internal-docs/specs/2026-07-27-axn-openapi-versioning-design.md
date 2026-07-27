# axn-openapi — Version Path Routing Design

**Tickets:** [PRO-2936](https://linear.app/teamshares/issue/PRO-2936/axn-axn-openapi) (this gem) · unblocked by [PRO-2955](https://linear.app/teamshares/issue/PRO-2955) (core `tool_version`, landed as teamshares/axn#197).
**Status:** Design approved in brainstorming; ready for implementation planning.
**Date:** 2026-07-27
**Supersedes:** the "Versioning (v1: none built-in)" section of `2026-07-18-axn-openapi-design.md`. That doc deferred versioning; core #197 now provides `tool_version`, and this doc replaces the deferral with the real routing design.

---

## Why

PRO-2955 gave core first-class `tool_version` and changed enumeration semantics: **`Axn.tools_for(:openapi)` now returns the *latest* version per `tool_name`.** For our HTTP surface that is the wrong default — the moment a downstream tool declares `tool_version 2`, the served endpoint for that tool would silently switch to v2, breaking the stable contract existing clients integrated against. We must move to **all-versions enumeration + explicit per-version path routing**, so a URL means exactly one version forever and adding a version only ever *adds* a path.

This is not backward-incompatible in practice: axn-openapi has not shipped, so there are no external clients pinned to the current bare `/{tool}` routing. That freedom is what lets us choose an explicit-version-only URL scheme with no bare/default path.

---

## Core API consumed (PRO-2955 / #197)

- `Axn.tools_for(:openapi, all_versions: true)` → every version class, sorted by `tool_name` then ascending `tool_version`.
- `Axn.versions_for(:openapi, tool_name)` → a `VersionGroup` (`.all` asc, `.latest`, `.default`). **Not used by this design** (see Decision 3) — noted for completeness.
- Each version is its own Axn class with its own `tool_version` (integer, defaults to 1 when undeclared), `tool_name(:openapi)`, `input_schema`, `output_schema`, `description`, `_semantic_hints`.

---

## Decisions

### 1. Explicit per-version paths only — no bare, no default, no latest

Every version is served at its own path, **version as a trailing segment**:

```
POST {path_prefix}/{tool_name}/v{tool_version}
```

- A **non-versioned tool** (`tool_version` == 1) is served at `/{tool_name}/v1` — there is no bare `/{tool_name}` path.
- There is **no bare/default path** and **no `/latest` alias**.

**Rationale.** A bare/default path can only serve either the oldest version (stale for new integrators) or the newest (drifts — a client that generated against it silently mismatches when a new version ships). Explicit-version-only has neither failure mode: `/{tool}/v1` is v1 for all time; `/{tool}/v2` is v2; adding a version never changes an existing path's meaning. Discoverability of "the newest version" is a *documentation* concern, not a routing one — the single `/openapi.json` lists every version, so "newest = highest N" is statically discoverable without a live route that changes behavior between deploys.

**Suffix, not prefix.** `/{tool}/v{n}`, not `/v{n}/{tool}`. Versioning here is **per-tool and ragged** (one tool may have v1+v2 while another has only v1, all described by a single `/openapi.json`). A leading `/v{n}/` conventionally signals an *API-wide* version, which we do not have and which would invite the wrong mental model (and expectations of a per-version spec document). A trailing `/v{n}` scopes the version to the tool honestly (`POST /approve_loan/v2` = "version 2 of the `approve_loan` operation") and groups a tool's versions under a common `/{tool}/*` path.

### 2. Enumerate all versions

`Axn::OpenAPI.tools` (currently `Axn.tools_for(:openapi)` at `lib/axn/openapi.rb`) switches to **`Axn.tools_for(:openapi, all_versions: true)`**, so the router and spec see every coexisting version, not just the latest.

### 3. The HTTP adapter ignores core's movable `default:` flag

No `.default` / `versions_for` in routing or spec generation. There is no "default version" concept in the HTTP surface — every version is equally addressable by its own URL, and none is privileged by a bare alias.

> Cross-adapter note (not actionable in this gem): with the HTTP adapter declining `.default` and the LLM adapters using `.latest`, core's `default: true` flag may have no real consumer. Worth raising on the axn side; out of scope here.

### 4. operationId

Each path's `operationId` is **`{tool_name}_v{tool_version}`**, uniform across every path (there is no bare path to name differently). `operationId` is **doc-local** — it exists only to make OpenAPI operations addressable for codegen. The **version is never encoded into `tool_name`** (the locked cross-adapter principle from PRO-2936/PRO-2955): `tool_name` stays the clean cross-adapter identity; the version lives only in the URL path and the doc-local `operationId`.

### 5. Per-version request/response schemas

Each version is its own Axn class, so each version's path carries that class's own `input_schema` (requestBody) and `output_schema` (200 response) — no extra machinery. Two versions of a tool with divergent contracts simply produce two paths with two different schemas.

### 6. One shared route table (Router and SpecGenerator cannot diverge)

Introduce a single internal builder — `Axn::OpenAPI::RouteTable` — that takes the enumerated version classes and produces the canonical, ordered list of route entries:

```
RouteEntry = { path:, axn:, operation_id: }
  path         # "{path_prefix}/{tool_name}/v{tool_version}"
  axn          # the version's Axn class
  operation_id # "{tool_name}_v{tool_version}"
```

- `Router` builds its exact-path dispatch map from `RouteTable` (`path → axn`).
- `SpecGenerator` emits one OpenAPI path per `RouteEntry`, keyed by `path`, with `operationId` = `operation_id`.

Because both consume the same builder, the routes the server answers and the paths the document advertises are guaranteed identical — directly addressing the "router + spec must agree on the path map" requirement. This is the one genuinely new unit; the rest is rewiring existing files to it.

### 7. Spec endpoint unchanged

`GET {path_prefix}/openapi.json` still serves one OpenAPI document describing every tool at every version. No per-version spec documents. No collision: `openapi.json` is a single `.json`-suffixed segment; tool paths are `/{tool}/v{n}` (`tool_name` is `[a-z0-9_]`, versions are `v\d+`).

---

## Routing behavior

Path (after stripping `path_prefix`) is matched exactly against the route table:

| Request | Result |
|---|---|
| `POST /{tool}/v{n}` matching a route-table entry | dispatch that version's Axn (unchanged Dispatcher path) |
| `POST /{tool}/v{n}` where `{tool}` is a known tool_name but `v{n}` is not an existing version | **404**, message pointing at the latest available version of that tool (see below) |
| `POST` to any other unmatched path (unknown tool_name, or malformed shape) | **404** (plain "unknown tool") |
| non-`POST` to a path that *would* match a tool/version, or to `/openapi.json` with the wrong verb | **405** |
| `GET {spec_path}` | the OpenAPI document |
| malformed JSON body on a matched route | **400** (unchanged) |

The status/envelope semantics and the Dispatcher are unchanged from the base gem — this feature only changes **which paths exist and which Axn each maps to**.

**404 with a latest-version pointer (helpful, not a route).** When a request targets `/{tool}/v{n}` where the `tool_name` exists at other versions but `v{n}` does not (e.g. `/{tool}/v3` when only v1/v2 exist), the 404 body's message names the latest available version's path (e.g. `"Unknown version v3 for tool 'calc'. Latest available: {prefix}/calc/v2."`). This is a purely informational error body computed from the route table's entries for that `tool_name` (`max` by `tool_version`) — **not** a routable `/latest` endpoint and **not** in the OpenAPI document, so it carries no contract or drift implications (it never appears in a success path or the spec). An entirely unknown `tool_name` (no matching entries) stays a plain 404 with no pointer.

---

## Integration points (existing files → change)

- **`lib/axn/openapi.rb`** — `self.tools` returns `Axn.tools_for(:openapi, all_versions: true)`.
- **`lib/axn/openapi/route_table.rb`** (new) — the shared `RouteTable` builder (Decision 6).
- **`lib/axn/openapi/router.rb`** — build the dispatch map from `RouteTable` (versioned exact-path keys) instead of `tool_name`-keyed; path matching + 404/405 as above.
- **`lib/axn/openapi/spec_generator.rb`** — emit one path per `RouteEntry`; `operationId` = `{tool}_v{n}`; each path's schemas from its own version class.
- **Existing specs** — the base gem's unit/integration tests assert bare `/{tool}` (e.g. `POST /api/echo_tool`); update to `/{tool}/v1` (e.g. `/api/echo_tool/v1`). Add multi-version coverage (a tool with v1 + v2 → two paths, two schemas, two operationIds; a request to a nonexistent version → 404).
- **`README.md` / `AGENTS-consuming.md`** — document the versioned URL scheme (`/{tool}/v{n}`, non-versioned ⇒ `/v1`), the absence of a bare/default/latest path, and that "newest" is discovered from the spec, not a magic route.

---

## Non-goals (v1)

- Bare `/{tool}` path, any default-version pinning, or consumption of core's `default:` flag.
- `/{tool}/latest` alias (deferred — purely additive; revisit if a concrete consumer appears).
- `/v{n}/{tool}` prefix form.
- Per-version OpenAPI documents.
- Any encoding of version into `tool_name`.

---

## Testing

- Unit: `RouteTable` produces the correct ordered entries for a mix of single- and multi-version tools; `Router` dispatches each versioned path and 404s a nonexistent version / 405s a wrong verb; `SpecGenerator` emits one path per version with `{tool}_v{n}` operationIds and per-version schemas.
- Integration (Rails dummy app): a mounted app serves `/{tool}/v1` for a non-versioned tool and distinct `/{tool}/v1` + `/{tool}/v2` for a two-version tool, each returning its own contract; `/openapi.json` lists all of them.
- Full `bundle exec rake verify` (Rails-free + dummy-app suites) pristine.
