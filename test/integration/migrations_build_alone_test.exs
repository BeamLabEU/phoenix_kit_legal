defmodule PhoenixKit.Modules.Legal.Integration.MigrationsBuildAloneTest do
  @moduledoc """
  This module's chain builds all of its tables exactly as core's chain does,
  on a database where core did not create them — the proof core needs before
  it stops creating them (core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`). Rows are not
  compared.

  `PhoenixKit.TestSupport.ModuleChainCheck` does the work in a scratch schema
  of its own, through `Ecto.Migrator` — so `ExUnit.Case`, not a sandboxed case,
  and `async: false`. Excluded (`:requires_module_chain_check`, see
  `test_helper.exs`) against a core that does not ship the check yet.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.TestSupport.ModuleChainCheck

  @moduletag :integration
  @moduletag :requires_module_chain_check
  @moduletag timeout: :timer.minutes(3)

  # Core's own migrations (V144 on) look the host repo up through
  # `PhoenixKit.RepoHelper`; this package's test config does not set it, so the
  # test points it at the test repo for its own duration.
  setup do
    previous = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, PhoenixKit.Modules.Legal.Test.Repo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :repo, previous),
        else: Application.delete_env(:phoenix_kit, :repo)
    end)
  end

  test "the chain builds the module's tables without core" do
    assert :ok =
             ModuleChainCheck.check(
               PhoenixKit.Modules.Legal.Test.Repo,
               PhoenixKit.Modules.Legal.Migrations
             )
  end
end
