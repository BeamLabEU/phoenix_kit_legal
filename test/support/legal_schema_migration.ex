defmodule PhoenixKit.Modules.Legal.Test.SchemaMigration do
  @moduledoc """
  Test-boot wrapper that lets `Ecto.Migrator` run
  `PhoenixKit.Modules.Legal.Migrations.up/1` and `.down/1` inside a real
  migration-runner context, exactly as the migration file `mix
  phoenix_kit.update` generates in a host app does. Needed because both
  functions call `execute/1` and (as of the adoption-shape check)
  `repo/0`, both only valid inside an active `Ecto.Migration.Runner`.

  Runs against `Ecto.Migration.prefix/0` — the migrator's OWN `:prefix`
  option (`Ecto.Migrator.run(Repo, ..., prefix: schema)`) — rather than a
  hardcoded `"public"`. DDL-running tests live only in their own schema,
  in their own database: the `:integration` suite isolates every scenario
  into its own throwaway schema (`legal_adoption_<unique>`), so neither
  this migration's own DDL nor `Ecto.Migrator`'s `schema_migrations`
  bookkeeping ever lands in a shared database's `public` schema.
  """
  use Ecto.Migration

  alias PhoenixKit.Modules.Legal.Migrations

  def up, do: Migrations.up(prefix: prefix())
  def down, do: Migrations.down(prefix: prefix())
end
