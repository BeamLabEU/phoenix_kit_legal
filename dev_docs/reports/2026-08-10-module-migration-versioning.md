# `phoenix_kit_consent_logs`: three DDLs, one table, and who actually owns it

**2026-08-10** · Resolved in **phoenix_kit_legal 0.3.0** and **0.3.1**.
**Ownership since revisited the same evening** — the drift cleanup below
stands, but the table's future shape now belongs to the module-owned chain
introduced in `2026-08-10-consent-logs-extraction.md` (the "core owns it"
pin was the stopgap that made that extraction safe to do properly).
**Written for review by the module's original author** — every claim below cites
a file, line or commit you can check yourself, and the commands to re-derive them
are included.

## TL;DR

`phoenix_kit_consent_logs` is a **core** table. It was created by core's **V43**,
in the same commit that first added the Legal module — back when Legal *was* part
of core. When Legal was extracted into this package, core kept V43. Nobody moved
the table, and nobody noticed core still owned it.

This package then accumulated **two more** definitions of the same table, neither
copied from V43, both drifting from it and from each other:

| # | Where | Ran? | Shape |
|---|---|---|---|
| 1 | core `V43` → squashed into `V135` | **Yes, on every install** | canonical |
| 2 | `lib/phoenix_kit_legal/migrations/consent_logs.ex` | never (see below) | `varchar(255/50/50)`, own index names |
| 3 | `priv/migrations/add_phoenix_kit_consent_logs.exs` | only if you followed the README | all `varchar(255)`, **no `if_not_exists`** |

Both #2 and #3 are deleted. Legal now declares no `migration_module/0` and ships
no DDL.

## The evidence that core owns it

```bash
# Same commit, both repos:
cd phoenix_kit      && git log --oneline -S"phoenix_kit_consent_logs" -- lib/ | tail -1
cd phoenix_kit_legal && git log --oneline -S"phoenix_kit_consent_logs" | tail -1
# → 801e66ca  Add Legal Module Phase 1 with V43 migration
```

`801e66ca` (timujeen, 2025-12-29) is *"Add Legal Module Phase 1 with V43
migration"*, and its own message says "Add `phoenix_kit_consent_logs` table for
user consent tracking". Legal was built **inside core**; the extraction into this
package carried the shared history, but the table stayed in core's chain.

V43 as originally written (`git show 801e66ca:lib/phoenix_kit/migrations/postgres/v43.ex`):

```elixir
create_if_not_exists table(:phoenix_kit_consent_logs, prefix: prefix) do
  add :user_id, :bigint, null: true
  add :session_id, :string, size: 64, null: true
  add :consent_type, :string, size: 30, null: false
  add :consent_given, :boolean, null: false, default: false
  add :consent_version, :string, size: 20, null: true
  add :ip_address, :string, size: 45, null: true
  add :user_agent_hash, :string, size: 64, null: true
  ...
```

Those sizes — **64 / 30 / 20 / 45 / 64** — are still core's today. Core has also
continued to *evolve* the table (`user_id :bigint` → `user_uuid :uuid` in the UUID
migration, V56). It has never stopped being core's.

Core 2.0 makes ownership explicit and enforceable:
`PhoenixKit.Migrations.ExpectedSchema` names the table, **all 11 columns, 6
indexes and the pkey constraint** as core-owned, and that manifest is what
`mix phoenix_kit.doctor` and `mix phoenix_kit.repair` verify a live database
against.

## Why copy #2 never ran

Two independent reasons, either sufficient:

1. **Core migrates first.** `mix phoenix_kit.update` runs the core chain
   (`phoenix_kit.update.ex:556`), then `run_module_migrations/1` (`:734`).
2. **Both DDLs are `CREATE TABLE IF NOT EXISTS`** — so by the time this module's
   `up/1` was reached, the table already existed and the statement was a no-op.

V135 is core's *unconditional* baseline: the table exists on every phoenix_kit
install, whether or not this package is present.

### The part worth your attention: PR #8 armed the rollback

`dev_docs/pull_requests/2026/8-fix-consentlogs-version-tracking/CLAUDE_REVIEW.md`
(2026-05-22) fixed a real protocol bug — `ConsentLogs` was missing
`current_version/0` and matched a map where core passes a keyword list, so core's
`try/rescue` swallowed the error and skipped the module entirely.

The fix was correct. **Its stated justification was not.** The review says:

> "On a clean install this meant `phoenix_kit_consent_logs` was never created."

That cannot have been true — core's V43 had been creating the table since
2025-12-29, five months earlier. What PR #8 actually changed is that the
coordinator went from *never invoked* to *invoked and no-op on `up`* — while
making **`down/1` reachable for the first time**:

```elixir
def down(opts \\ []) do
  execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_consent_logs CASCADE")
end
```

That is a `DROP TABLE ... CASCADE` on a **core-owned table that outlives this
package**. This is precisely the trap `phoenix_kit_hello_world#34` documents:
while the version is inferred from table existence, an always-dropping `down/1`
looks unreachable and harmless — repair the version marker and you arm it. It was
armed here, in this repo, by a PR whose review found "no blocking issues".

Nothing was lost, because nothing has rolled Legal back. But it was one
`mix ecto.rollback` away from taking core's consent audit trail with it.

## Copy #3: the README template that could actually break an install

`priv/migrations/add_phoenix_kit_consent_logs.exs`, which README step 1 told users
to copy into their app and run with `mix ecto.migrate`:

```elixir
create table(:phoenix_kit_consent_logs, primary_key: false) do
  add :session_id, :string          # Ecto default → varchar(255); core: 64
  add :consent_type, :string, null: false   # → varchar(255); core: 30
  add :consent_version, :string     # → varchar(255); core: 20
  add :ip_address, :string          # → varchar(255); core: 45
  add :user_agent_hash, :string     # → varchar(255); core: 64
```

Two problems:

- **`create table`, not `create_if_not_exists`.** On any install where core had
  already created the table — i.e. all of them — this raises
  `table "phoenix_kit_consent_logs" already exists` and the migration fails.
- **Every string column is `varchar(255)`**, and the index names are Ecto's
  defaults (`phoenix_kit_consent_logs_user_uuid_index`), a *third* naming scheme
  distinct from both core's (`..._idx`) and copy #2's (`idx_consent_logs_...`).

The install task never told you to do this — `phoenix_kit_legal.install.ex:322`
correctly says "Apply the consent_logs migration: `mix phoenix_kit.update`". The
README and the install task have been contradicting each other.

**If you previously ran this template and it succeeded**, your host predates core
creating the table, and your table has 255-wide columns and Ecto-default index
names. `mix phoenix_kit.doctor` on core 2.0 will report the divergence; `mix
phoenix_kit.repair` is the supported way to reconcile it. Nothing in this package
will touch it.

## Full divergence table

Copy #2 (this package's coordinator) vs core:

| Column | Copy #2 | Core (V43 → V135 / `ExpectedSchema`) |
|---|---|---|
| `session_id` | `varchar(255)` | **`varchar(64)`** |
| `consent_type` | `varchar(50) NOT NULL` | **`varchar(30)`** |
| `consent_version` | `varchar(50)` | **`varchar(20)`** |
| `metadata` | `jsonb NOT NULL DEFAULT '{}'` | `jsonb DEFAULT '{}'` (nullable) |
| `inserted_at` / `updated_at` | `NOT NULL DEFAULT NOW()` | `NOT NULL`, no default |
| `uuid` | inline `PRIMARY KEY` | column + separate pkey constraint |

Indexes disagreed wholesale:

- **Copy #2:** `idx_consent_logs_user_uuid` and `idx_consent_logs_session_id` are
  **partial** (`WHERE ... IS NOT NULL`); plus `idx_consent_logs_consent_type`,
  `idx_consent_logs_inserted_at` (DESC).
- **Core:** `phoenix_kit_consent_logs_{user_uuid,session_id,type,inserted_at}_idx`,
  plus a composite `..._session_type_idx (session_id, consent_type)` and
  `..._uuid_unique_index` that copy #2 had no equivalent of.

## The bug the drift was masking

`ConsentLog`'s changeset had **no length validation on any field** — check
`consent_log.ex` before 0.3.0. That was survivable while the table was believed to
be 255-wide. Against core's actual widths it is not: `ConsentLog.create/1` is
public API host apps call, so an over-long `session_id` (>64) or
`consent_version` (>20) reaches Postgres and returns a raw varchar-overflow
`Postgrex.Error` rather than a changeset error the caller can handle.

Fixed in 0.3.0, at core's exact widths: `session_id` 64, `consent_type` 30,
`consent_version` 20, `ip_address` 45, `user_agent_hash` 64.

## What changed

**0.3.0**
- Removed `migration_module/0` from `PhoenixKit.Modules.Legal`. It is an optional
  callback defaulting to `nil` (`phoenix_kit/lib/phoenix_kit/module.ex:506`,
  `:557`), so Legal simply drops out of the module-migration list.
- Deleted `lib/phoenix_kit_legal/migrations/consent_logs.ex` (copy #2).
- Added the length validations above.

**0.3.1**
- Deleted `priv/migrations/add_phoenix_kit_consent_logs.exs` (copy #3) and
  rewrote README step 1 to match what the install task already printed.
- Added `test/consent_logs_ownership_test.exs`, which fails if a
  `migration_module/0`, a coordinator module, or a `priv/` DDL template
  reappears — verified by reintroducing each and watching it fail, not just by
  watching it pass. (The first draft of that test used
  `refute function_exported?/3`, which passes vacuously for an unloaded module
  *and* would have been wrong anyway, since `use PhoenixKit.Module` injects a
  `defoverridable` default `migration_module, do: nil`. It asserts the returned
  value now.)
- Added a schema-ownership section to this repo's `AGENTS.md`.

**Runtime behaviour is unchanged by the removals.** A migration that never ran
cannot stop running, and the README template was never part of the supported
install path the task prints.

## If this table ever needs to change

The change belongs in **core's** chain. Adding a coordinator back here would
recreate the conflict, and core's `ExpectedSchema` would disagree with whatever
it produced. The ownership test is there to make that decision deliberate rather
than accidental.
