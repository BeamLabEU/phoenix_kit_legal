# The consent-logs migration conflict, and why Legal ceded the table

**2026-08-10** · Resolved in **phoenix_kit_legal 0.3.0**.

`phoenix_kit_hello_world#34` referenced this report while fixing the migration
template that Legal's coordinator was copied from. The report did not exist —
this is it, written after re-deriving the finding from the repositories rather
than from that PR's summary.

## What was wrong

`PhoenixKit.Modules.Legal` declared:

```elixir
@impl PhoenixKit.Module
def migration_module, do: PhoenixKit.Modules.Legal.Migrations.ConsentLogs
```

and shipped `lib/phoenix_kit_legal/migrations/consent_logs.ex`, a versioned
coordinator whose `up/1` created `phoenix_kit_consent_logs`.

**That migration had never run on any host, and could not.**

## Why: Legal was originally part of core

The decisive evidence is in the git history of both repositories. Commit
`801e66ca`, *"Add Legal Module Phase 1 with V43 migration"*, is present in
**both** `phoenix_kit` and `phoenix_kit_legal` — the Legal module was built
inside core, and core's **V43** created `phoenix_kit_consent_logs`. When Legal
was later extracted into its own package, the extraction carried the shared
history, but **core kept V43**.

The standalone coordinator was then written *fresh* for the extracted package,
from the Ecto schema rather than copied from V43. That is where the shapes
diverged — nobody reconciled them because nobody noticed core still owned the
table.

Core 2.0 squashed `V01`..`V134` into a single `V135` baseline, so that DDL now
lives at `phoenix_kit/lib/phoenix_kit/migrations/postgres/v135.ex:1051`.

## Why it could never run

Two independent reasons, either sufficient:

1. **Core migrates first.** `mix phoenix_kit.update` runs the core chain
   (`phoenix_kit.update.ex:556`) and only then `run_module_migrations/1`
   (`:734`). Both DDLs are `CREATE TABLE IF NOT EXISTS`, so by the time Legal's
   `up/1` is reached the table exists and the statement is a no-op.
2. **The table is core infrastructure.** V135 is core's unconditional baseline —
   it creates `phoenix_kit_consent_logs` on every phoenix_kit install, whether
   or not `phoenix_kit_legal` is present.

## The divergence, for the record

Legal's DDL vs. core's canonical shape:

| Column | Legal's coordinator | Core (V135 / `ExpectedSchema`) |
|---|---|---|
| `session_id` | `varchar(255)` | **`varchar(64)`** |
| `consent_type` | `varchar(50) NOT NULL` | **`varchar(30)`** |
| `consent_version` | `varchar(50)` | **`varchar(20)`** |
| `metadata` | `jsonb NOT NULL DEFAULT '{}'` | `jsonb DEFAULT '{}'` (nullable) |
| `inserted_at` / `updated_at` | `NOT NULL DEFAULT NOW()` | `NOT NULL`, no default |
| `uuid` | inline `PRIMARY KEY` | column, pkey added as a separate constraint |

Indexes disagreed wholesale — different names *and* different definitions:

- Legal: `idx_consent_logs_user_uuid` and `idx_consent_logs_session_id` are
  **partial** (`WHERE ... IS NOT NULL`), plus `idx_consent_logs_consent_type`
  and `idx_consent_logs_inserted_at` (DESC).
- Core: `phoenix_kit_consent_logs_user_uuid_idx`, `..._session_id_idx`,
  `..._type_idx`, `..._inserted_at_idx`, plus a composite
  `..._session_type_idx (session_id, consent_type)` and
  `..._uuid_unique_index` that Legal had no equivalent of.

Had both ever run, a host would carry two overlapping index sets forever.

## Why it still mattered, given it never ran

Three live hazards, not one:

1. **`down/1` was a loaded gun.** It ran
   `DROP TABLE IF EXISTS phoenix_kit_consent_logs CASCADE` — against a table
   core owns and that exists without this package. This is exactly the trap
   `phoenix_kit_hello_world#34` documents: while the version is inferred from
   table existence, an always-dropping `down/1` looks unreachable; repair the
   version marker and you arm it.
2. **Two sources of truth for the same schema**, drifting further apart with
   every change to either.
3. **Core 2.0 made the disagreement enforceable.**
   `PhoenixKit.Migrations.ExpectedSchema` now names the table, all 11 columns,
   6 indexes and the pkey constraint as core-owned, and
   `mix phoenix_kit.doctor` / `mix phoenix_kit.repair` verify a live database
   against it. Legal's shape was not merely different — it was a shape core
   would report as damage.

## What was done

- **Removed `migration_module/0`.** It is an optional callback defaulting to
  `nil` (`phoenix_kit/lib/phoenix_kit/module.ex:506`, `:557`), so Legal simply
  stops declaring one and drops out of the module-migration list. A comment in
  its place records why, and says not to re-add it.
- **Deleted `lib/phoenix_kit_legal/migrations/consent_logs.ex`.**
- **Added the length validations the drift was masking.** `ConsentLog`'s
  changeset had *no* length validation on any field, while core's columns are
  narrower than the old DDL assumed. `ConsentLog.create/1` is public API for
  host apps, so an over-long `session_id` (>64) or `consent_version` (>20)
  surfaced as a raw `Postgres` varchar-overflow error rather than a changeset
  error the caller could handle. Now validated at core's exact widths.

**Runtime behaviour is unchanged by the removal** — a migration that never ran
cannot stop running.

## If you need to change this table

The change belongs in **core's** migration chain, not here. Adding a
coordinator back to this package would recreate the conflict, and core's
`ExpectedSchema` would disagree with whatever it produced.
