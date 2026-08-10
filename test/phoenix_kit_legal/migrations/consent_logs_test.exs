defmodule PhoenixKit.Modules.Legal.Migrations.ConsentLogsTest do
  @moduledoc """
  Guards the parts of the versioned-migration contract that can be checked
  without a database.

  The DDL itself needs a real Postgres and is covered by
  `test/scripts/verify_consent_logs_migration.exs` — see AGENTS.md, "Module
  migrations". What is pinned here is the shape Core's `mix phoenix_kit.update`
  depends on, and the two behaviours whose absence caused the defects reported in
  `dev_docs/reports/2026-08-10-module-migration-versioning.md`:

    * the module answers every function Core calls, at the arity it calls it;
    * an unusable prefix raises instead of being reported as "not installed",
      because 0 means "no schema here" and would send Core off to install one
      over live data.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Migrations.ConsentLogs

  test "Legal points Core at this migration module" do
    assert Legal.migration_module() == ConsentLogs
  end

  test "implements the protocol mix phoenix_kit.update calls" do
    for {fun, arity} <- [
          current_version: 0,
          up: 1,
          down: 1,
          migrated_version: 1,
          migrated_version_runtime: 1
        ] do
      assert function_exported?(ConsentLogs, fun, arity),
             "#{inspect(ConsentLogs)}.#{fun}/#{arity} is part of the migration " <>
               "protocol Core calls; removing it makes the module invisible to " <>
               "`mix phoenix_kit.update`"
    end
  end

  test "target version is above the initial version" do
    assert ConsentLogs.current_version() > 0
    assert ConsentLogs.current_version() >= ConsentLogs.initial_version()
  end

  test "an invalid prefix raises rather than reporting version 0" do
    for prefix <- ["bad-prefix", "public; DROP TABLE phoenix_kit_consent_logs", "", :public] do
      assert_raise ArgumentError, fn ->
        ConsentLogs.migrated_version_runtime(prefix: prefix)
      end
    end
  end
end
