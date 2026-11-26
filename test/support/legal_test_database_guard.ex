defmodule PhoenixKit.Modules.Legal.Test.DatabaseGuard do
  @moduledoc """
  The `:integration` suite (`test/phoenix_kit_legal/migrations/
  adoption_integration_test.exs`) runs real DDL — `CREATE`/`DROP SCHEMA`,
  fixture tables, `Migrations.up/1`/`.down/1` — against whatever database
  `PGDATABASE` resolves to. That database must be this package's own
  disposable fixture and nothing else: never another package's test
  database, never a shared or development database. `test_helper.exs` calls
  `validate!/1` on the resolved name before doing anything else that could
  touch it.
  """

  @pattern ~r/^(pk\d+_)?phoenix_kit_legal_test\d*$/

  @doc """
  Whether `name` is this package's own disposable test database — always
  `phoenix_kit_legal_test`, optionally with a numeric partition suffix
  (`MIX_TEST_PARTITION`, e.g. `phoenix_kit_legal_test1`) and optionally
  with a `pk<N>_` box prefix (`pk3_phoenix_kit_legal_test`: a shared
  Postgres that hosts one copy of each package's fixture per dev box names
  them this way). An allowlist, not a denylist: any other name is refused,
  including another package's own `_test`-suffixed fixture (prefixed or
  not) and any shared or development database.
  """
  @spec safe?(String.t()) :: boolean()
  def safe?(name), do: Regex.match?(@pattern, name)

  @doc "Raises unless `name` is `safe?/1`."
  @spec validate!(String.t()) :: :ok
  def validate!(name) do
    if safe?(name) do
      :ok
    else
      raise """
      PGDATABASE=#{inspect(name)} does not look like this package's own \
      disposable test database — refusing to run the integration suite \
      against it.

      This suite runs real DDL. Point PGDATABASE at phoenix_kit_legal_test \
      (optionally with a numeric MIX_TEST_PARTITION suffix, e.g. \
      phoenix_kit_legal_test1, and/or a pk<N>_ box prefix, e.g. \
      pk3_phoenix_kit_legal_test) — never another package's or core's own \
      test or development database.
      """
    end
  end
end
