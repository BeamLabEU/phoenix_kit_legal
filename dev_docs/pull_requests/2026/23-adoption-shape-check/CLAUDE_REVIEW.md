# PR #23 Review — Verify phoenix_kit_consent_logs shape before stamping the adoption marker

**Repo:** `BeamLabEU/phoenix_kit_legal`
**Commit:** `6e0255f` (squash-merged to `main`)
**Author:** Tymofii Shapovalov
**Reviewer:** Claude Opus 5.5
**Date:** 2026-09-24
**Related:** `BeamLabEU/phoenix_kit#862`
**Verdict:** **APPROVE with one post-merge fix.** The shape check is sound and
reads its expected shape from the DDL it guards, not from a second copy. One
latent bug: the check ran on every `up/1` call, not only on adoption. It is
fixed below.

---

## Overview

V1's `CREATE TABLE IF NOT EXISTS` proved only that a table with the right name
existed. After this PR, `up/1` first reads the existing table's columns,
indexes and primary key from the Postgres catalogs. It then diffs them
(`AdoptionShape.diff/2`) against the shape parsed out of `up_statements/1`.
On drift, it either raises (`:raise`, the default) or logs and proceeds
(`:warn`). The PR also adds a Postgres-backed `:integration` suite with
per-test schema isolation and a database-name allowlist guard.

Verified by reading the producing code:

- `information_schema.columns.data_type` gives exactly the base types the DDL
  parser produces (`character varying`, `timestamp with time zone`, `uuid`,
  `jsonb`, `boolean`), and `character_maximum_length` holds the width. So both
  sides of the comparison use the same vocabulary.
- `pg_indexes.indexdef` renders `CREATE [UNIQUE] INDEX name ON schema.table
  USING btree (cols)`, which the shared regex parses. The extra `_pkey` index
  that `pg_indexes` also returns does no harm, because `diff_indexes/2` only
  walks the expected side.
- A raise inside the runner aborts the migration transaction before any
  `execute/1` is flushed, and `Ecto.Migrator` records nothing. So the
  "retried automatically" claim holds.

## Findings

### BUG - MEDIUM — The shape check ran on every `up/1`, not only on adoption (fixed)

`enforce_adoption_shape!/1` ran whenever the table existed, marker or not.
Core's updater (`PhoenixKit.Migrations.Modules`) compares
`migrated_version_runtime/1` against `current_version/0` and calls `up/1`
again for every later chain version. The expected shape comes from
`up_statements/1`, and `parsed_expected_indexes/1` flat-maps over every
statement. So the first V2 that adds an index with `CREATE INDEX IF NOT
EXISTS`, or a column in the `CREATE TABLE`, would have read as
`:missing_index`/`:missing_column` drift on every V1-adopted host. Under the
default `:raise`, the upgrade would have been blocked everywhere. Nothing
triggers this today because only V1 exists. But the chain exists to own the
table's *future* shape, so V2 is the next step.

`AdoptionShape.format/1`'s own `:warn` text also said that once the marker is
written "this check will NOT run again automatically". That was false before
this fix and is true after it.

**Fix:** `enforce_adoption_shape!/1` now verifies only when the table carries
no `pkl_schema:<N>` marker (`with 0 <- adopted_version(prefix), {:drift,
diffs} <- verify_adoption_shape(prefix)`). `adopted_version/1` reads the
marker over the runner's connection. It shares `marker_query/0` and
`marker_version/1` with `migrated_version_runtime/1`, so the marker SQL exists
once. `verify_adoption_shape/1` is unchanged and still public. A `down/1` to 0
clears the marker, so re-adoption is verified again.

**Tests:**
- `consent_logs_ownership_test.exs`: a new source pin checks that
  `enforce_adoption_shape!/1` gates on `adopted_version/1` before calling
  `verify_adoption_shape/1`. The `repo().query` count pin goes from 4 to 5,
  and `adopted_version` is added to the list of designated catalog readers.
- `adoption_integration_test.exs`: adopts a canonical table, widens
  `session_id` to 255, re-runs `up/1` under `:raise` with a new migration
  version, and asserts that there is no raise, the marker stays, and the
  drift is left alone.

Docs updated to match: the `Migrations` moduledoc, the `up/1` doc, AGENTS.md
and `dev_docs/guides/consent-logs-ownership.md`.

### NITPICK — Partitioned tables read as absent (not changed)

`table_exists?/1` and the marker query filter on `relkind = 'r'`. A
partitioned `phoenix_kit_consent_logs` (`relkind = 'p'`) would skip
verification. The `CREATE TABLE IF NOT EXISTS` would then no-op, and the
`COMMENT` would stamp the marker. Left alone: nothing in the ecosystem
partitions this table, and the marker query already had the same filter
before this PR.

### NITPICK — Documentation volume (not changed)

The same `:raise`/`:warn` explanation now appears five times: in the
moduledoc, the `AdoptionShapeError` moduledoc, `format/1`'s runtime message,
AGENTS.md and the guide. The runtime message runs to about 40 lines inside an
exception. Every copy is accurate, but keeping them in sync costs effort, and
a shorter exception message with a pointer to the guide would read better at
3 a.m. This is a style call, so it is left to the author.

## Validation

- `mix test`: 123 tests, 0 failures, 10 excluded.
- `mix precommit`: clean.
- **The `:integration` suite (including the new test) was not run.** The only
  database this environment's Postgres user can connect to is a shared one,
  which `DatabaseGuard` correctly refuses, and the user lacks the privilege
  to `createdb phoenix_kit_legal_test`. Run `mix test --only integration`
  against a dedicated database before relying on the new integration test.

## Also fixed in the release commit

- AGENTS.md still listed the gettext locales as `en`, `et`, `ru`. #21 added
  `de` and `fr`, so both mentions are updated.
