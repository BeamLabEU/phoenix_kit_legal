import Config

# Integration tests (tagged `:integration`) exercise
# `PhoenixKit.Modules.Legal.Migrations.up/1` against a real PostgreSQL
# database — the adoption-shape check it runs
# (`PhoenixKit.Modules.Legal.Migrations.AdoptionShape`) reads live catalog
# state that no pure-function test can stand in for. `test_helper.exs`
# probes this connection before `ExUnit.start/1` and excludes
# `:integration` automatically when it is unreachable — see AGENTS.md,
# "Testing".
#
# First-time setup: createdb phoenix_kit_legal_test
#
# This database must be dedicated to this package — the integration suite
# runs real DDL against it. `test_helper.exs` validates the resolved name
# (`PhoenixKit.Modules.Legal.Test.DatabaseGuard.validate!/1`) before
# anything connects; that check, not this file, is what refuses an unsafe
# name.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_legal_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

config :phoenix_kit_legal, PhoenixKit.Modules.Legal.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  database: pg_test_db,
  pool_size: 2

config :logger, level: :warning
