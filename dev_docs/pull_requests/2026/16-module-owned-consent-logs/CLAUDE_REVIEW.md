# PR #16 — Adopt the module-owned migration chain for `phoenix_kit_consent_logs`

**Author:** timujinne · **Branch:** `feat/module-owned-consent-logs` · **Reviewed:** 2026-08-11

Moves ownership of the table's future shape into
`PhoenixKit.Modules.Legal.Migrations` (marker `pkl_schema:<N>`), with V1 as a
shape-identical adoption.

## Verified against core, claim by claim

Every load-bearing assertion in the PR body was checked against core rather
than taken on trust:

| Claim | Result |
|---|---|
| V1's widths are core's | ✓ core V135 is `64 / 30 / 20 / 45 / 64`; `ConsentLog.column_widths/0` matches exactly |
| V1 uses core's exact object names | ✓ pkey + all six index names match `v135.ex` verbatim, including the `pg_constraint` DO-block shape |
| No FK to replicate | ✓ core declares **no** foreign key on `consent_logs.user_uuid` — only the index. V1 correctly omits one |
| `uuid_generate_v7()` is schema-qualified | ✓ `#{p}uuid_generate_v7()`, matching core |
| The manifest step exists | ✓ `@excluded_exact` at `dev_docs/squash/generate_baseline.exs:1056` |
| `mix phoenix_kit.repair` exists | ✓ `lib/mix/tasks/phoenix_kit.repair.ex` |
| Core still audits the table | ✓ `ExpectedSchema` carries all 11 columns + 6 indexes as `owner: :core` |

The design is right. `down/1` unstamping rather than dropping is the correct
call for a GDPR/CCPA audit trail, `validated_prefix/1` guards the DDL
interpolation, and V1-as-adoption genuinely does avoid a core release and the
release-ordering hazard that would come with one.

Confirmed the `pkl_schema:` marker is safe to put on a core-owned table: core
only reads a table COMMENT for its own `phoenix_kit` version row
(`postgres.ex`, `repair.ex`), and `ExpectedSchema` does not audit comments, so
`doctor`/`repair` will not see it as drift.

---

## IMPROVEMENT - HIGH — the manifest cross-check only compared varchar widths

`"every width core declares is the width this package declares"` filters
core's manifest to columns whose `create` matches `character varying\((\d+)\)`
and compares the number. That is a real check, but it leaves the rest of
"shape-identical" unguarded:

- a column added to or missing from V1's `CREATE TABLE`
- a wrong type on any non-varchar column (`jsonb`, `boolean`, `uuid`, both
  timestamps)
- a wrong or missing `DEFAULT` — `'{}'::jsonb`, `false`,
  `<prefix>.uuid_generate_v7()`
- a wrong `NOT NULL`

All of those pass the width test while breaking the invariant the whole
extraction report rests on. It is also the same blind spot as the incident
being cleaned up: the three drifted DDLs agreed on whatever somebody had
thought to compare.

**Fixed.** Added `"every column core declares matches V1's, in full"`. It
builds `%{type, default, not_null}` per column from the newest revision of each
manifest entry, parses the same triple back out of V1's `CREATE TABLE`, and
asserts the column-name sets and every shape are equal.

Nullability comes from `revisions` rather than from the `create` string on
purpose: core omits `NOT NULL` from the `ADD COLUMN` form for `inserted_at` and
`updated_at` (it backfills those separately), so comparing `create` text would
produce two false mismatches. Column *position* is deliberately not compared —
the manifest's `pos` reflects the historical build-up order (V43's `uuid`,
`user_uuid` first), which does not match the order `v135.ex`'s `CREATE TABLE`
lists, so it is not a meaningful equality.

Mutation-verified: dropping `DEFAULT '{}'::jsonb` from V1's `metadata` column
fails the new test and passes every pre-existing one.

## NITPICK — `down/1` to target 0 erases a foreign table comment

`down_statements(prefix, 0)` emits `COMMENT ON TABLE … IS NULL`. The design
explicitly anticipates that an adopted table may already carry someone else's
prose comment (that is why the reader treats prose as version 0) — a rollback
to 0 would delete it rather than restore it. Not fixed: core does not comment
this table, so there is nothing to lose on any real install today, and
preserving it would mean stashing the original somewhere the chain can find it
later. Recorded so it is a known edge rather than a surprise.

---

## Verification

- `mix test` — 62 tests, 0 failures (16 in the rewritten ownership file).
- `mix precommit` (incl. dialyzer) — clean, exit 0.
- ⚠️ No PostgreSQL in the review environment. Every test above is a
  pure-data check on `up_statements/1` / `down_statements/2` and runs without a
  database, so this suite is fully exercised — but the wrapper-migration path
  (`mix phoenix_kit.update` generating and running the stamp) is **not**
  covered here and needs a DB run before release.
