# `phoenix_kit_consent_logs`: the extraction to a module-owned chain

**2026-08-10, evening** · Follows `2026-08-10-module-migration-versioning.md`
(same day, earlier): that report killed the two drifted in-package DDL copies
and pinned the table as core-owned as a stopgap. This one is the deliberate
extraction that the stopgap made safe — the table's future shape moves to a
module-owned migration chain, per the workspace policy (hello_world 0.2.0:
"a module ships the DDL for its own tables") that core's
`PhoenixKit.Migrations.Modules` docs already anticipate by naming
`phoenix_kit_legal` among the chain-owning modules.

## Why extraction is safe NOW when it produced drift before

The 0.3.0 incident was never about ownership — it was about **two copies of
the DDL nobody compared**. The chain introduced here cannot recreate that
class of bug:

* `Migrations.up_statements/1` **interpolates** `ConsentLog.column_widths/0`.
  There is no second statement of the numbers anywhere in the package; the
  schema validations, the producers and the DDL read one map.
* The statements are exposed **as data**, and the ownership test parses them:
  widths must equal `column_widths/0`, object names must be core V135's names
  verbatim, everything must be `IF NOT EXISTS`-guarded, and no statement in
  either direction may match `DROP|TRUNCATE|DELETE`.

## The division of labour with core (V1)

| Concern | Owner |
|---|---|
| Creating the table on today's installs | core V135 baseline (unchanged) |
| The table's version marker (`pkl_schema:<N>` COMMENT) | this chain |
| The table's FUTURE shape (V2+) | this chain |
| Auditing/repairing the V135 shape (`doctor` / `repair`) | core's `ExpectedSchema` — still accurate, because V1 changes no shape |

**V1 is adoption**: `CREATE TABLE IF NOT EXISTS` (finds the table on every
current install), core's exact pkey/index names re-asserted idempotently, then
the marker stamp. `down/1` only unstamps — the rows are the GDPR/CCPA audit
trail, and rollback of a module must never destroy them.

Because V1 changes no shape, **no core release is required** and there is no
release-ordering hazard: legal ships alone.

## What each audience does

**Existing hosts with Legal installed** — upgrade the package, run
`mix phoenix_kit.update` as always. Core detects the chain (version 0 in the
DB < current 1), writes a wrapper migration into the host's
`priv/repo/migrations/` and runs it; the only observable change is the
`pkl_schema:1` comment on the table. Commit the wrapper. Nothing else.

**New hosts** — `mix phoenix_kit_legal.install`, then `mix phoenix_kit.update`,
exactly as the install task already says. Today the table arrives via core's
V135 and V1 adopts it; on any future core whose baseline no longer creates the
table, the identical statements create it. Both paths end in the same schema.

**Hosts without Legal** — nothing changes. Core's baseline still creates the
(empty) table and core's manifest still audits it, exactly as before this
package existed.

## The V2+ shape-change protocol

The first chain version that ALTERS the table must, in this order:

1. change `ConsentLog.column_widths/0` (if a width) — the changeset, the
   producers and the DDL follow automatically;
2. add the chain version (new statements in `up_statements/1`, version-aware
   `down_statements/2`, bump `@current_version`);
3. **before release**, add the altered objects to the manifest generator's
   `@excluded_exact` in core (`dev_docs/squash/generate_baseline.exs`) and
   regenerate `ExpectedSchema` — the same maintainer-tooling step the
   projects/document_creator chains use, so core's `repair` stops asserting
   the old shape (the columns/indexes the doc/project chains iterate are
   already excluded this way);
4. raise this package's core floor to the release that ships the regenerated
   manifest.

Until step 3 lands, core's `mix phoenix_kit.repair` would try to restore the
V135 shape — that is why the ownership test pins V1 as shape-identical and
why a width change alone (without the core step) must fail review.

## Rollback story

`mix phoenix_kit.update`'s generated wrapper delegates `down/1` to the chain:
target 0 removes the marker, a positive target restamps it. The table and its
rows survive any rollback by construction (test-pinned).
