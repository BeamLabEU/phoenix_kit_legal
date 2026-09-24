defmodule PhoenixKit.Modules.Legal.Test.Repo do
  @moduledoc """
  Test-only Ecto repo for the `:integration` suite
  (`test/phoenix_kit_legal/migrations/adoption_integration_test.exs`).

  Configured in `config/test.exs`, started by `test/test_helper.exs` only
  after a successful connection probe and a database-name safety check
  (`PhoenixKit.Modules.Legal.Test.DatabaseGuard`). No sandbox: these tests
  exercise DDL (`Migrations.up/1`/`down/1`, plus manual
  `CREATE`/`ALTER`/`DROP` to stage pre-existing table shapes) inside a
  real migration-runner transaction, which Ecto's sandbox is not built to
  nest inside — each test creates and drops its own throwaway Postgres
  schema instead (`legal_adoption_<unique>`, `CASCADE`-dropped in
  `on_exit`). See `adoption_integration_test.exs`'s moduledoc.
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_legal,
    adapter: Ecto.Adapters.Postgres
end
