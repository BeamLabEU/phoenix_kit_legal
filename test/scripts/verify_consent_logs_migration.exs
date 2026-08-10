# End-to-end verification of PhoenixKit.Modules.Legal.Migrations.ConsentLogs
# against a real Postgres. The DDL cannot be exercised by the ExUnit suite, which
# runs without a repo, so this script owns the parts that only a database can
# answer: that a rollback to a non-zero version keeps the table, that Core V43's
# prose table comment reads as V1 instead of 0, that V2 converges both V1 shapes,
# and that a named-schema install resolves `uuid_generate_v7()`.
#
#   mix run test/scripts/verify_consent_logs_migration.exs
#
# Creates and drops its own scratch database (PGDATABASE is ignored). Connection
# comes from PGHOST/PGPORT/PGUSER/PGPASSWORD when set, else a local postgres —
# note that a dev config may already export PGHOST, so pass it explicitly if the
# connection is refused: `PGHOST=127.0.0.1 mix run <this file>`.
# Exits non-zero on the first failed expectation.
alias PhoenixKit.Modules.Legal.Migrations.ConsentLogs

defmodule VRepo do
  use Ecto.Repo, otp_app: :phoenix_kit_legal, adapter: Ecto.Adapters.Postgres
end

db = "legal_migr_verify"

conn = [
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres")
]

# Recreate the scratch database.
{:ok, admin} = Postgrex.start_link(conn ++ [database: "postgres"])
Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{db} WITH (FORCE)", [])
Postgrex.query!(admin, "CREATE DATABASE #{db}", [])
GenServer.stop(admin)

Application.put_env(:phoenix_kit_legal, VRepo, conn ++ [database: db, pool_size: 2])
Application.put_env(:phoenix_kit, :repo, VRepo)
{:ok, _} = VRepo.start_link()

defmodule H do
  def q(sql, params \\ []), do: VRepo.query!(sql, params, log: false).rows

  def comment(prefix \\ "public") do
    case q(
           """
           SELECT pg_catalog.obj_description(c.oid,'pg_class') FROM pg_class c
           JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE c.relname='phoenix_kit_consent_logs' AND n.nspname=$1
           """,
           [prefix]
         ) do
      [[c]] -> c
      [] -> :no_table
    end
  end

  def exists?(prefix \\ "public") do
    [[e]] =
      q(
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name='phoenix_kit_consent_logs' AND table_schema=$1)",
        [prefix]
      )

    e
  end

  def col(name, prefix \\ "public") do
    case q(
           "SELECT character_maximum_length, is_nullable FROM information_schema.columns WHERE table_schema=$1 AND table_name='phoenix_kit_consent_logs' AND column_name=$2",
           [prefix, name]
         ) do
      [[len, nullable]] -> {len, nullable}
      [] -> :missing
    end
  end

  def indexes(prefix \\ "public") do
    q(
      "SELECT indexname FROM pg_indexes WHERE schemaname=$1 AND tablename='phoenix_kit_consent_logs' ORDER BY 1",
      [prefix]
    )
    |> List.flatten()
  end

  # Index definitions with the schema name stripped, so two schemas are
  # comparable. Names alone are not enough: `CREATE INDEX IF NOT EXISTS` matches
  # on name, so a definition that differs (say `DESC` on one path) survives
  # forever on whichever path created it first.
  def index_defs(prefix) do
    q(
      "SELECT indexdef FROM pg_indexes WHERE schemaname=$1 AND tablename='phoenix_kit_consent_logs' ORDER BY indexname",
      [prefix]
    )
    |> List.flatten()
    |> Enum.map(&String.replace(&1, "#{prefix}.", ""))
  end

  # Column types, excluding ordinal position: the two install paths inherit
  # different column ORDER (core's V43 order versus this module's CREATE TABLE)
  # and reconciling that would need a full table rewrite. Types, widths and
  # nullability must match; order is allowed to differ.
  def column_types(prefix) do
    q(
      "SELECT column_name, data_type, character_maximum_length, is_nullable, column_default FROM information_schema.columns WHERE table_schema=$1 AND table_name='phoenix_kit_consent_logs' ORDER BY column_name",
      [prefix]
    )
    |> Enum.map(fn row ->
      # Defaults name their own schema (`legal_alt.uuid_generate_v7()`), so strip
      # it before comparing two schemas.
      Enum.map(row, fn
        value when is_binary(value) -> String.replace(value, "#{prefix}.", "")
        value -> value
      end)
    end)
  end

  def check(label, actual, expected) do
    if actual == expected do
      IO.puts("  PASS  #{label}")
    else
      IO.puts(
        "  FAIL  #{label}\n        expected: #{inspect(expected)}\n        actual:   #{inspect(actual)}"
      )

      Process.put(:failed, true)
    end
  end
end

defmodule Run do
  alias PhoenixKit.Modules.Legal.Migrations.ConsentLogs

  # Each Ecto.Migrator.up/4 needs a distinct version, otherwise schema_migrations
  # makes the second call a silent no-op.
  def up(prefix, version) do
    mod = wrapper(:up, prefix, version)

    Ecto.Migrator.up(VRepo, :os.system_time(:microsecond), mod,
      log: false,
      log_migrations_sql: false
    )
  end

  def down(prefix, version) do
    mod = wrapper(:down, prefix, version)

    Ecto.Migrator.up(VRepo, :os.system_time(:microsecond), mod,
      log: false,
      log_migrations_sql: false
    )
  end

  defp wrapper(direction, prefix, version) do
    name = Module.concat([:"VWrap#{System.unique_integer([:positive])}"])

    # Unquote the resolved module atom rather than writing the name inside the
    # quote: the generated module has its own alias scope, so an alias written in
    # there would not resolve.
    coordinator = ConsentLogs

    body =
      quote do
        use Ecto.Migration

        def up do
          case unquote(direction) do
            :up ->
              unquote(coordinator).up(prefix: unquote(prefix), version: unquote(version))

            :down ->
              unquote(coordinator).down(prefix: unquote(prefix), version: unquote(version))
          end
        end
      end

    {:module, mod, _, _} = Module.create(name, body, Macro.Env.location(__ENV__))
    mod
  end
end

IO.puts("\n=== A. fresh install: 0 -> 2 ===")

H.check(
  "runtime version on empty database",
  ConsentLogs.migrated_version_runtime(prefix: "public"),
  0
)

Run.up("public", 2)
H.check("table exists", H.exists?(), true)
H.check("version marker", H.comment(), "2")
H.check("runtime version", ConsentLogs.migrated_version_runtime(prefix: "public"), 2)
H.check("session_id widened", H.col("session_id"), {255, "YES"})
H.check("consent_type", H.col("consent_type"), {50, "NO"})
H.check("metadata not null", H.col("metadata"), {nil, "NO"})

H.check("canonical indexes", H.indexes(), [
  "phoenix_kit_consent_logs_inserted_at_idx",
  "phoenix_kit_consent_logs_pkey",
  "phoenix_kit_consent_logs_session_id_idx",
  "phoenix_kit_consent_logs_session_type_idx",
  "phoenix_kit_consent_logs_type_idx",
  "phoenix_kit_consent_logs_user_uuid_idx"
])

IO.puts("\n=== B. idempotency: up to 2 again ===")
Run.up("public", 2)
H.check("still V2", H.comment(), "2")

IO.puts("\n=== C. rollback 2 -> 1 keeps the data, 1 -> 0 drops ===")

H.q(
  "INSERT INTO phoenix_kit_consent_logs (consent_type, consent_given) VALUES ('analytics', true)"
)

Run.down("public", 1)
H.check("table survived a rollback to V1", H.exists?(), true)
H.check("row survived", H.q("SELECT count(*) FROM phoenix_kit_consent_logs"), [[1]])
H.check("version marker back to 1", H.comment(), "1")
H.check("metadata nullable again", H.col("metadata"), {nil, "YES"})
Run.down("public", 0)
H.check("rollback to 0 drops the table", H.exists?(), false)
H.check("runtime version after drop", ConsentLogs.migrated_version_runtime(prefix: "public"), 0)

IO.puts("\n=== D. legacy Core-V43 shape: prose comment reads as V1, V2 converges ===")
# Reproduces what a real host actually has: core's V43 CREATE TABLE, then the
# later core steps that replaced its identity (V44 adds `uuid`, V74 drops
# `user_id` for `user_uuid`). Column order, widths, index names and definitions
# below are copied from a live install, not invented.
H.q("""
CREATE TABLE phoenix_kit_consent_logs (
  id bigserial PRIMARY KEY,
  user_id bigint,
  session_id varchar(64),
  consent_type varchar(30) NOT NULL,
  consent_given boolean NOT NULL DEFAULT false,
  consent_version varchar(20),
  ip_address varchar(45),
  user_agent_hash varchar(64),
  metadata jsonb DEFAULT '{}',
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
)
""")

H.q(
  "ALTER TABLE phoenix_kit_consent_logs ADD COLUMN uuid uuid DEFAULT uuid_generate_v7() NOT NULL, ADD COLUMN user_uuid uuid"
)

H.q("ALTER TABLE phoenix_kit_consent_logs DROP CONSTRAINT phoenix_kit_consent_logs_pkey")
H.q("ALTER TABLE phoenix_kit_consent_logs DROP COLUMN id, DROP COLUMN user_id")
H.q("ALTER TABLE phoenix_kit_consent_logs ADD PRIMARY KEY (uuid)")

H.q(
  "COMMENT ON TABLE phoenix_kit_consent_logs IS 'User consent tracking for GDPR/CCPA compliance cookie banners'"
)

H.q(
  "CREATE INDEX phoenix_kit_consent_logs_inserted_at_idx ON phoenix_kit_consent_logs (inserted_at)"
)

H.q(
  "CREATE INDEX phoenix_kit_consent_logs_session_id_idx ON phoenix_kit_consent_logs (session_id)"
)

H.q(
  "CREATE INDEX phoenix_kit_consent_logs_session_type_idx ON phoenix_kit_consent_logs (session_id, consent_type)"
)

H.q("CREATE INDEX phoenix_kit_consent_logs_type_idx ON phoenix_kit_consent_logs (consent_type)")
H.q("CREATE INDEX phoenix_kit_consent_logs_user_uuid_idx ON phoenix_kit_consent_logs (user_uuid)")
H.q("CREATE INDEX idx_consent_logs_session_id ON phoenix_kit_consent_logs (session_id)")

H.q(
  "INSERT INTO phoenix_kit_consent_logs (consent_type, consent_given, metadata) VALUES ('marketing', true, NULL)"
)

H.check(
  "prose comment reads as V1, not 0 and not a crash",
  ConsentLogs.migrated_version_runtime(prefix: "public"),
  1
)

Run.up("public", 2)
H.check("version marker", H.comment(), "2")
H.check("session_id widened from 64", H.col("session_id"), {255, "YES"})
H.check("consent_type widened from 30", H.col("consent_type"), {50, "NO"})
H.check("consent_version widened from 20", H.col("consent_version"), {50, "YES"})
H.check("metadata backfilled and NOT NULL", H.col("metadata"), {nil, "NO"})

H.check(
  "existing NULL metadata backfilled",
  H.q("SELECT metadata FROM phoenix_kit_consent_logs"),
  [[%{}]]
)

H.check("legacy index dropped", "idx_consent_logs_session_id" in H.indexes(), false)
H.check("canonical index present", "phoenix_kit_consent_logs_session_id_idx" in H.indexes(), true)

IO.puts("\n=== E. named-schema (prefix) install ===")
H.q("CREATE SCHEMA IF NOT EXISTS legal_alt")

H.check(
  "runtime version in empty schema",
  ConsentLogs.migrated_version_runtime(prefix: "legal_alt"),
  0
)

Run.up("legal_alt", 2)
H.check("table in prefix schema", H.exists?("legal_alt"), true)
H.check("version marker in prefix schema", H.comment("legal_alt"), "2")
H.check("public schema untouched at 2", H.comment("public"), "2")

H.check(
  "uuid default resolves in prefix schema",
  H.q(
    "INSERT INTO legal_alt.phoenix_kit_consent_logs (consent_type, consent_given) VALUES ('necessary', true) RETURNING (uuid IS NOT NULL)"
  ),
  [[true]]
)

IO.puts("\n=== F. invalid prefix must raise, not report 0 ===")

raised =
  try do
    ConsentLogs.migrated_version_runtime(prefix: "bad-prefix; DROP TABLE x")
    :no_raise
  rescue
    ArgumentError -> :raised
  end

H.check("invalid prefix raises ArgumentError", raised, :raised)

IO.puts("\n=== G. current_version ===")
H.check("current_version", ConsentLogs.current_version(), 2)

# `public` reached V2 by converging the legacy core-created shape (D);
# `legal_alt` reached V2 by running V1 then V2 on an empty schema (E). If the
# reconciliation is complete, the two are now indistinguishable — and this is the
# check that catches a definition that differs while the index NAME matches,
# which `CREATE INDEX IF NOT EXISTS` would otherwise let through forever.
IO.puts("\n=== H. the two install paths converge ===")

H.check(
  "column types, widths and defaults identical",
  H.column_types("public"),
  H.column_types("legal_alt")
)

H.check("index definitions identical", H.index_defs("public"), H.index_defs("legal_alt"))

IO.puts("")

if Process.get(:failed) do
  IO.puts("RESULT: FAILURES PRESENT")
  System.halt(1)
else
  IO.puts("RESULT: all checks passed")
end
