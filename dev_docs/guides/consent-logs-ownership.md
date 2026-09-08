# Consent-log ownership and the consent-config endpoint

Why `phoenix_kit_consent_logs` is created by core but evolved here, what the
adoption step does, and why the consent-config controller lives in core.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Database & migrations,
Conventions.

## This module owns the shape of one core-created table

`phoenix_kit_consent_logs` is created by core's migration chain — it ships in
core's squashed V135 baseline — so it exists on every PhoenixKit install, with
or without this package. Core's `PhoenixKit.Migrations.ExpectedSchema` still
names the table, all 11 columns, 6 indexes and the pkey as core-owned
(`owner: :core`), and that manifest is what `mix phoenix_kit.doctor` and
`mix phoenix_kit.repair` verify live databases against.

This package owns the table's **future** shape, through
`PhoenixKit.Modules.Legal.Migrations` — returned by `migration_module/0`. V1 of
that chain is an *adoption*, not a create: `CREATE TABLE IF NOT EXISTS` with
core's exact object names, then a `pkl_schema:1` comment marker. It changes no
shape, which is why core's manifest stays accurate and no core release was
required. Rationale and the per-audience upgrade paths:
[`../reports/2026-08-10-consent-logs-extraction.md`](../reports/2026-08-10-consent-logs-extraction.md).

The two facts are not in tension. Core creates the table and audits its current
shape; this chain versions what happens to it next.

### What V1 is

  * on existing installs the table is already there, the
    `CREATE TABLE IF NOT EXISTS` finds it, and the only new object is the
    `pkl_schema:1` marker — from then on this chain owns the table's future
    shape;
  * on a hypothetical future install whose core baseline no longer creates the
    table, the same statements create it — shape-identical to core's V135, with
    core's exact index and constraint names.

The migrated version is tracked as a `pkl_schema:<N>` COMMENT on
`phoenix_kit_consent_logs` (the marker convention from the projects chain,
namespaced). A marker-less table reads as version 0 — the core-baseline shape
before this chain existed.

### What the chain must never do

Pinned by `test/consent_logs_ownership_test.exs`, to the degree each bullet
says:

- **Never restate a column width.** Every varchar width in the DDL is
  interpolated from `ConsentLog.column_widths/0`, this package's single width
  authority. Three separate DDLs for this one table had accumulated — core's, a
  coordinator here, and a copy-into-your-app template the README pointed at —
  all disagreeing on widths and index names
  ([`../reports/2026-08-10-module-migration-versioning.md`](../reports/2026-08-10-module-migration-versioning.md)).
  A second copy of those numbers is how that happened.
- **Never ship a migration template under `priv/`.** Hosts migrate through
  `mix phoenix_kit.update`, which discovers the chain and writes the wrapper
  itself.
- **Never emit `DROP`, `TRUNCATE` or `DELETE`, and never call any of Ecto's
  other destructive macros** (`drop`, `drop_if_exists`, `rename`,
  `alter ... do remove ... end`) **either.** The rows are a GDPR/CCPA consent
  audit trail, and on every current install the table is core-created; `down/1`
  unstamps the marker and does nothing else.

  **The test suite's coverage of this rule is partial**, not the airtight
  guarantee the line above might suggest: `neither direction executes SQL of
  its own` catches a literal `execute("DROP TABLE ...")` written past the
  builder, but not `drop(table(...))`, `drop_if_exists(...)` or `rename(...)` —
  all reach the database exactly as directly and none touch `execute(`, which
  is the only thing that test's regex looks for. Verified, not assumed:
  [`../reports/2026-08-19-executed-path-guard-allowlist-gap.md`](../reports/2026-08-19-executed-path-guard-allowlist-gap.md)
  reproduces all three against a clean `main`, each leaving all eighteen tests
  in `consent_logs_ownership_test.exs` green. Closing it needs an allowlist over
  what is actually executed, not another denylist entry — that report has the
  reasoning and what it would take.

### Changing the table's shape

Changing the table's shape is a chain version (V2+), and it is **not** a
free-standing change: it must follow the excluded-object protocol in the
extraction report, because core's manifest audits the V135 shape until core's
generated baseline excludes the altered objects. A width change that skips that
step should fail review.

## Consent config endpoint contract

`GET /phoenix_kit/api/consent-config` is **owned by core**, not by this package.
Core declares the route unconditionally and its
`PhoenixKitWeb.Controllers.ConsentConfig` answers 204 when this package is
absent, or delegates to `Legal.get_consent_widget_config/0` when it is present.

**Do not define a consent-config controller here.** This package used to define
`PhoenixKitWeb.Controllers.ConsentConfigController`. Core deliberately did *not*
reuse that name — a host resolving new core against an old release of this
package would otherwise have one module compiled into two applications, with
code-path order deciding which answers. Reintroducing either name here
re-creates that hazard.

The corollary is a release-ordering rule: deleting the controller makes core's
version a *hard* requirement, because core declares the route whenever
`PhoenixKit.Modules.Legal` is loaded. On a core older than 1.7.227 that route
still points at `…ConsentConfigController` — the module this package used to
own — so every request raises `UndefinedFunctionError`, a 500 per page load,
since core's bundled `phoenix_kit.js` fetches the endpoint on
`DOMContentLoaded` whenever the widget root was not server-rendered. Nothing
catches it at compile time: Phoenix compiles routes to literal tuples, so a
missing controller produces no warning. Hence the floor cannot go below
1.7.227. The actual pin in `mix.exs`, `{:phoenix_kit, "~> 2.0"}`, is higher than
that floor requires — raised independently, for reasons unrelated to this hazard
(this package does not call core's migration internals; see the `mix.exs`
comment above the dependency line) — so it satisfies the constraint without
being read as proof the constraint sits at 2.0. If the pin is ever lowered,
1.7.227 remains the true minimum.
