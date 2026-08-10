defmodule PhoenixKit.Modules.Legal.ConsentLogsOwnershipTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal

  @moduledoc """
  Pins the decision that `phoenix_kit_consent_logs` is a **core** table and this
  package ships no DDL for it.

  Background, with the evidence: `dev_docs/reports/2026-08-10-module-migration-versioning.md`.

  Short version: the table was created by core's V43 — in the same commit that
  first added the Legal module, when Legal was still part of core — and stayed in
  core's chain when this package was extracted. Core 2.0's
  `PhoenixKit.Migrations.ExpectedSchema` names the table, all 11 columns, 6
  indexes and the pkey as core-owned, and `mix phoenix_kit.doctor` verifies live
  databases against it.

  This package nonetheless accumulated two more definitions of the same table,
  both drifted from core and from each other. They are gone. These tests fail if
  either comes back, because the failure mode is silent: a second DDL behind a
  `CREATE TABLE IF NOT EXISTS` is invisible until the day something drops or
  alters the table out from under core.

  If you are here because a test failed and you believe this module *should* own
  the table, read the report first — the answer is almost certainly that the
  schema change belongs in core's migration chain.
  """

  test "Legal declares no migration_module/0" do
    # Assert the VALUE, not `function_exported?/3`. Two traps:
    #
    #   * `use PhoenixKit.Module` injects a `defoverridable` default
    #     `def migration_module, do: nil`, so the function is ALWAYS exported —
    #     exportedness says nothing about whether this module declares one.
    #   * `function_exported?/3` returns false for a module that is merely not
    #     loaded yet, so a `refute function_exported?` here passes vacuously.
    #
    # Declaring a real one puts this package into `mix phoenix_kit.update`'s
    # module-migration list — where its `up/1` can only ever be a no-op (core
    # creates the table first), while its `down/1` becomes a live
    # `DROP TABLE ... CASCADE` against a core-owned table.
    assert Code.ensure_loaded?(Legal)

    assert Legal.migration_module() == nil,
           """
           PhoenixKit.Modules.Legal declares migration_module/0 again \
           (returns #{inspect(Legal.migration_module())}).

           `phoenix_kit_consent_logs` belongs to core (V43, now the V135 baseline).
           A coordinator here cannot create it — core migrates first, and both
           DDLs are CREATE TABLE IF NOT EXISTS — but its down/1 CAN drop it.

           See dev_docs/reports/2026-08-10-module-migration-versioning.md
           """
  end

  test "no migration coordinator module is compiled into the package" do
    refute Code.ensure_loaded?(Legal.Migrations.ConsentLogs),
           """
           Legal.Migrations.ConsentLogs is back.

           This module was deleted in 0.3.0. Its DDL disagreed with core's on
           four column widths, the metadata nullability, the timestamp defaults
           and every index name.

           See dev_docs/reports/2026-08-10-module-migration-versioning.md
           """
  end

  test "no migration template is shipped in priv/" do
    # `priv/migrations/add_phoenix_kit_consent_logs.exs` was a copy-into-your-app
    # template the README pointed at. It used `create table` rather than
    # `create_if_not_exists`, so on any install where core had already created
    # the table it failed outright — and it declared every string column as the
    # Ecto default varchar(255) against core's 64/30/20/45/64.
    priv = :code.priv_dir(:phoenix_kit_legal) |> to_string()
    stray = Path.wildcard(Path.join([priv, "migrations", "*.exs"]))

    assert stray == [],
           """
           Migration templates found in priv/: #{inspect(stray)}

           This package ships no DDL for phoenix_kit_consent_logs. Hosts get the
           table from core's chain via `mix phoenix_kit.update`, which is what
           `mix phoenix_kit_legal.install` already tells them to run.

           See dev_docs/reports/2026-08-10-module-migration-versioning.md
           """
  end

  describe "ConsentLog changeset guards core's column widths" do
    alias PhoenixKit.Modules.Legal.ConsentLog

    # Core's widths, from PhoenixKit.Migrations.ExpectedSchema. Without these
    # validations an over-long value reaches Postgres and comes back as a raw
    # varchar-overflow error — `create/1` is public API, so the caller has no
    # way to check first.
    test "rejects a session_id longer than core's varchar(64)" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: String.duplicate("a", 65)
        })

      refute changeset.valid?
      assert {"should be at most %{count} character(s)", _} = changeset.errors[:session_id]
    end

    test "rejects a consent_version longer than core's varchar(20)" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: "s",
          consent_version: String.duplicate("9", 21)
        })

      refute changeset.valid?
      assert {"should be at most %{count} character(s)", _} = changeset.errors[:consent_version]
    end

    test "accepts values at exactly core's limits" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: String.duplicate("a", 64),
          consent_version: String.duplicate("9", 20),
          ip_address: String.duplicate("f", 45),
          user_agent_hash: String.duplicate("0", 64)
        })

      assert changeset.valid?
    end
  end
end
