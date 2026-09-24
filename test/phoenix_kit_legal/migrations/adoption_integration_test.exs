defmodule PhoenixKit.Modules.Legal.Migrations.AdoptionIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  DB-backed integration coverage for `Migrations.up/1`'s adoption-shape
  check (`Migrations.verify_adoption_shape/1` + `AdoptionShape.diff/2`)
  against a real PostgreSQL catalog — the half
  `migrations/adoption_shape_test.exs`'s hand-built fixtures cannot stand
  in for: does Postgres's OWN `information_schema.columns` / `pg_indexes`
  / `pg_constraint` reporting actually parse into the shape this chain
  compares against?

  ## Rule: DDL-running tests live only in their own schema, in their own database

  Every test here creates its own `legal_adoption_<unique>` Postgres
  schema, creates fixture tables and runs `Migrations.up/1`/`.down/1` with
  `prefix: schema` (via `Ecto.Migrator.run(..., prefix: schema)`, which
  scopes `Ecto.Migrator`'s OWN `schema_migrations` bookkeeping into that
  same schema too — not just the objects this chain's DDL creates), and
  drops the schema (`CASCADE`) in `on_exit`. Nothing in this file
  references `public.phoenix_kit_consent_logs` or `public.schema_migrations`
  by an unqualified name — see the "isolation from the shared database"
  describe block below, which proves the isolation holds rather than
  asserting it in a comment. `PhoenixKit.Modules.Legal.Test.DatabaseGuard`
  (`test_helper.exs`) separately refuses to run this suite at all against
  anything but this package's own dedicated database.

  Runs `Migrations.up/1`/`down/1` for real, through a live
  `Ecto.Migration.Runner` context (`Ecto.Migrator.run/4` +
  `PhoenixKit.Modules.Legal.Test.SchemaMigration`) rather than calling
  `up_statements/1`/`down_statements/2` directly — `up/1` now runs
  `enforce_adoption_shape!/1` BEFORE any DDL, and its two outcomes (under
  the default `:raise`, nothing is altered and the marker is never
  written; under `:warn`, the marker IS written despite the drift) can
  only be proven by exercising `up/1` itself, not by orchestrating its
  pieces by hand.

  `@moduletag :integration` — excluded automatically by `test_helper.exs`
  when no database is reachable. `async: false`: `Ecto.Migrator` takes its
  own advisory lock per repo, so concurrent runs against the same pool
  would serialize or contend regardless of schema isolation — no benefit
  to `async: true` here.
  """

  @moduletag :integration

  alias PhoenixKit.Modules.Legal.Migrations.AdoptionShapeError
  alias PhoenixKit.Modules.Legal.Test.Repo
  alias PhoenixKit.Modules.Legal.Test.SchemaMigration

  # Each test's schema is fresh, so there is no persistent
  # `schema_migrations` row across DIFFERENT tests to collide with — every
  # test can reuse version 1 for its FIRST `run_up`/`run_down` safely.
  # Within a single test that calls `run_up` more than once (the
  # idempotent-re-run case below), a fixed version is wrong for a
  # different reason: `Ecto.Migrator` records a version as applied in
  # `schema_migrations` and skips re-running an already-applied one, so a
  # second `run_up(schema, 1)` would silently no-op — the mutation "up/1
  # raises on its second real invocation" would pass this test with ZERO
  # actual second invocation happening. `run_up/2`'s version parameter
  # exists for exactly that case: pass a version `Ecto.Migrator` hasn't
  # seen in this schema yet to force a real second call.
  @migration_version 1

  setup do
    schema = "legal_adoption_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{schema}")

    # `up_statements/1`'s CREATE TABLE defaults `uuid` to
    # `#{prefix}.uuid_generate_v7()` — schema-qualified, so it must exist
    # IN THIS SCHEMA specifically, not just somewhere on the search path.
    # Normally shipped by core's migration baseline, which this bare test
    # setup deliberately does not run (see test_helper.exs). A stand-in is
    # enough here: these tests exercise shape verification, not UUIDv7's
    # monotonic ordering.
    Repo.query!("""
    CREATE FUNCTION #{schema}.uuid_generate_v7() RETURNS uuid AS $BODY$
      SELECT gen_random_uuid();
    $BODY$ LANGUAGE sql;
    """)

    on_exit(fn -> Repo.query!("DROP SCHEMA IF EXISTS #{schema} CASCADE") end)

    {:ok, schema: schema}
  end

  describe "fresh install (no pre-existing table)" do
    test "up/1 is a no-op verification and creates the canonical table", %{schema: schema} do
      run_up(schema)

      assert marker(schema) == "pkl_schema:1"
    end
  end

  describe "a canonical (core V135-shaped) pre-existing table" do
    test "up/1's verification accepts it, adopts it, and the row survives", %{schema: schema} do
      create_canonical_table(schema)
      row_id = insert_row!(schema)

      run_up(schema)

      assert marker(schema) == "pkl_schema:1"
      assert row_count(schema) == 1
      assert row_ids(schema) == [row_id]
    end

    test "re-running up/1 a second time (idempotent re-run) leaves the marker at pkl_schema:1",
         %{schema: schema} do
      create_canonical_table(schema)

      # Two DISTINCT versions — see @migration_version's comment. Reusing
      # the same version here would make Ecto.Migrator skip the second
      # `run_up` entirely, so `Migrations.up/1` would only ever run ONCE
      # and this test would pass even if a second real call to it crashed.
      run_up(schema, 1)
      assert marker(schema) == "pkl_schema:1"

      run_up(schema, 2)
      assert marker(schema) == "pkl_schema:1"
    end
  end

  describe "a legacy/narrowed table (pre-0.3.0 varchar(255) shape)" do
    test "up/1 refuses to adopt it under :raise (the default), and nothing is touched",
         %{schema: schema} do
      create_legacy_table(schema)
      row_id = insert_row!(schema)

      assert_raise AdoptionShapeError, fn -> run_up(schema) end

      assert marker(schema) == nil
      assert row_count(schema) == 1
      assert row_ids(schema) == [row_id]
      assert session_id_max_length(schema) == 255
    end

    test "under :warn, up/1 logs the diff, writes the marker anyway, and does not raise",
         %{schema: schema} do
      create_legacy_table(schema)
      row_id = insert_row!(schema)

      set_adoption_shape_check_mode!(:warn)
      log = ExUnit.CaptureLog.capture_log(fn -> run_up(schema) end)

      assert log =~ "phoenix_kit_consent_logs already exists"
      assert log =~ "session_id"
      # The marker IS written despite the drift — see Migrations' moduledoc
      # for why: withholding it would leave this migration pending forever,
      # reusing the same generated migration file and re-attempting it on
      # every mix phoenix_kit.update without ever converging.
      assert marker(schema) == "pkl_schema:1"
      assert row_count(schema) == 1
      assert row_ids(schema) == [row_id]
      assert session_id_max_length(schema) == 255
    end

    test "under :warn, a table whose primary key exists under a DIFFERENT name still fails — with a raw Postgres error, not AdoptionShapeError",
         %{schema: schema} do
      # Legacy shape, but its own inline (unnamed) PRIMARY KEY, which
      # Postgres names <table>_pkey by default — the exact name
      # up_statements/1's DO-block guard also uses, so THIS specific
      # legacy shape does not collide. Give it an explicitly different
      # name instead, matching a host that renamed or hand-created its
      # constraint under a different name — plausible drift, not
      # constructed to defeat the guard.
      Repo.query!("""
      CREATE TABLE #{schema}.phoenix_kit_consent_logs (
        uuid uuid DEFAULT gen_random_uuid(),
        session_id character varying(255),
        consent_type character varying(255) NOT NULL,
        consent_given boolean NOT NULL DEFAULT false,
        consent_version character varying(255),
        ip_address character varying(255),
        user_agent_hash character varying(255),
        metadata jsonb NOT NULL DEFAULT '{}',
        inserted_at timestamp with time zone NOT NULL DEFAULT now(),
        updated_at timestamp with time zone NOT NULL DEFAULT now(),
        user_uuid uuid,
        CONSTRAINT my_own_pk_name PRIMARY KEY (uuid)
      )
      """)

      set_adoption_shape_check_mode!(:warn)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert_raise Postgrex.Error, ~r/multiple primary keys/, fn -> run_up(schema) end
        end)

      # The diff was still logged first — :warn attempted to proceed and
      # only failed inside up_statements/1's own DDL, not before logging.
      assert log =~ "phoenix_kit_consent_logs already exists"
      # And still no marker — the COMMENT is the LAST statement
      # up_statements/1 emits, so a mid-list failure never reaches it.
      assert marker(schema) == nil
    end
  end

  describe "an already-adopted table (pkl_schema marker present)" do
    test "a later up/1 skips the shape check, even under :raise, and leaves the drift alone",
         %{schema: schema} do
      create_canonical_table(schema)
      run_up(schema, 1)
      assert marker(schema) == "pkl_schema:1"

      # Drift introduced AFTER adoption stands in for what a V2 upgrade
      # looks like to the check: up_statements/1 declaring something the
      # adopted table does not have yet. Re-verifying here would raise on
      # every already-adopted install instead of upgrading it.
      Repo.query!("""
      ALTER TABLE #{schema}.phoenix_kit_consent_logs
      ALTER COLUMN session_id TYPE character varying(255)
      """)

      run_up(schema, 2)

      assert marker(schema) == "pkl_schema:1"
      assert session_id_max_length(schema) == 255
    end
  end

  describe "a failed migration under :raise is not recorded as applied" do
    test "a normal retry with the SAME version succeeds once the table is reconciled by hand",
         %{schema: schema} do
      create_canonical_table(schema)

      Repo.query!("""
      ALTER TABLE #{schema}.phoenix_kit_consent_logs
      ALTER COLUMN session_id TYPE character varying(32)
      """)

      assert_raise AdoptionShapeError, fn -> run_up(schema, @migration_version) end
      refute migration_recorded?(schema, @migration_version)

      # What an operator does by hand — never something this migration
      # runs itself.
      Repo.query!("""
      ALTER TABLE #{schema}.phoenix_kit_consent_logs
      ALTER COLUMN session_id TYPE character varying(64)
      """)

      # The SAME version as the failed attempt — an ordinary
      # mix ecto.migrate retry, nothing special about it. It only picks
      # the migration back up because Ecto.Migrator never marked
      # @migration_version applied in schema_migrations after it raised.
      run_up(schema, @migration_version)
      assert marker(schema) == "pkl_schema:1"
    end
  end

  describe "down/1 never drops the table" do
    test "unstamps the marker but leaves the table and its row intact", %{schema: schema} do
      create_canonical_table(schema)
      row_id = insert_row!(schema)

      run_up(schema)
      assert marker(schema) == "pkl_schema:1"

      run_down(schema)

      assert marker(schema) == nil
      assert table_exists?(schema)
      assert row_ids(schema) == [row_id]
    end
  end

  describe "isolation from the shared database" do
    test "an adoption scenario never touches public.phoenix_kit_consent_logs or public.schema_migrations",
         %{schema: schema} do
      before_snapshot = public_snapshot()

      create_canonical_table(schema)
      insert_row!(schema)
      run_up(schema)
      run_down(schema)

      assert public_snapshot() == before_snapshot
    end
  end

  # Application.fetch_env/2, not get_env/3 with a hardcoded fallback —
  # restoring via a hardcoded fallback would leave an explicit :raise in
  # the app env for the rest of the suite even when the key was never set
  # before this test, masking a mutation to the CODE's own default
  # depending on test run order.
  defp set_adoption_shape_check_mode!(mode) do
    previous = Application.fetch_env(:phoenix_kit_legal, :adoption_shape_check)
    Application.put_env(:phoenix_kit_legal, :adoption_shape_check, mode)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit_legal, :adoption_shape_check, value)
        :error -> Application.delete_env(:phoenix_kit_legal, :adoption_shape_check)
      end
    end)
  end

  defp run_up(schema, version \\ @migration_version) do
    Ecto.Migrator.run(Repo, [{version, SchemaMigration}], :up,
      all: true,
      log: false,
      prefix: schema
    )
  end

  defp run_down(schema, version \\ @migration_version) do
    Ecto.Migrator.run(Repo, [{version, SchemaMigration}], :down,
      all: true,
      log: false,
      prefix: schema
    )
  end

  defp to_regclass(qualified_name) do
    %{rows: [[value]]} = Repo.query!("SELECT to_regclass($1)", [qualified_name])
    value
  end

  # A full snapshot, not just an OID — the OID alone proves the table
  # wasn't dropped and recreated, but says nothing about whether its
  # columns, indexes or comment (the marker's home) were touched in place.
  defp public_snapshot do
    %{
      consent_logs_oid: to_regclass("public.phoenix_kit_consent_logs"),
      consent_logs_columns: public_table_columns("phoenix_kit_consent_logs"),
      consent_logs_indexes: public_table_indexes("phoenix_kit_consent_logs"),
      consent_logs_comment: public_table_comment("phoenix_kit_consent_logs"),
      schema_migrations_oid: to_regclass("public.schema_migrations")
    }
  end

  defp public_table_columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, character_maximum_length, is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY column_name
        """,
        [table]
      )

    rows
  end

  defp public_table_indexes(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1 ORDER BY indexname",
        [table]
      )

    rows
  end

  # `obj_description(...::regclass, ...)` raises if the regclass cast
  # can't resolve — guard with to_regclass/1 first rather than catching.
  defp public_table_comment(table) do
    if to_regclass("public.#{table}") do
      %{rows: [[value]]} =
        Repo.query!("SELECT obj_description('public.#{table}'::regclass, 'pg_class')")

      value
    end
  end

  defp migration_recorded?(schema, version) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM #{schema}.schema_migrations WHERE version = $1", [version])

    rows != []
  end

  defp marker(schema) do
    %{rows: [[value]]} =
      Repo.query!(
        "SELECT obj_description('#{schema}.phoenix_kit_consent_logs'::regclass, 'pg_class')"
      )

    value
  end

  defp table_exists?(schema) do
    to_regclass("#{schema}.phoenix_kit_consent_logs") != nil
  end

  defp row_count(schema) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{schema}.phoenix_kit_consent_logs")
    count
  end

  defp row_ids(schema) do
    %{rows: rows} = Repo.query!("SELECT uuid FROM #{schema}.phoenix_kit_consent_logs")
    Enum.map(rows, fn [id] -> id end)
  end

  defp session_id_max_length(schema) do
    %{rows: [[max_length]]} =
      Repo.query!(
        """
        SELECT character_maximum_length FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'phoenix_kit_consent_logs' AND column_name = 'session_id'
        """,
        [schema]
      )

    max_length
  end

  defp insert_row!(schema) do
    %{rows: [[row_id]]} =
      Repo.query!("""
      INSERT INTO #{schema}.phoenix_kit_consent_logs (session_id, consent_type, inserted_at, updated_at)
      VALUES ('sess-1', 'necessary', now(), now())
      RETURNING uuid
      """)

    row_id
  end

  # Independent of `up_statements/1` by design — core's V43 → V135 shape,
  # hand-written rather than derived from the same source. A bug shared
  # between `up_statements/1` and the verifier's own parsing would not
  # silently pass this test the way it would if both sides were built
  # from the same DDL.
  defp create_canonical_table(schema) do
    Repo.query!("""
    CREATE TABLE #{schema}.phoenix_kit_consent_logs (
      session_id character varying(64),
      consent_type character varying(30) NOT NULL,
      consent_given boolean DEFAULT false NOT NULL,
      consent_version character varying(20),
      ip_address character varying(45),
      user_agent_hash character varying(64),
      metadata jsonb DEFAULT '{}'::jsonb,
      inserted_at timestamp with time zone NOT NULL,
      updated_at timestamp with time zone NOT NULL,
      uuid uuid DEFAULT #{schema}.uuid_generate_v7() NOT NULL,
      user_uuid uuid,
      CONSTRAINT phoenix_kit_consent_logs_pkey PRIMARY KEY (uuid)
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX phoenix_kit_consent_logs_uuid_unique_index ON #{schema}.phoenix_kit_consent_logs USING btree (uuid)"
    )

    Repo.query!(
      "CREATE INDEX phoenix_kit_consent_logs_inserted_at_idx ON #{schema}.phoenix_kit_consent_logs USING btree (inserted_at)"
    )

    Repo.query!(
      "CREATE INDEX phoenix_kit_consent_logs_session_id_idx ON #{schema}.phoenix_kit_consent_logs USING btree (session_id)"
    )

    Repo.query!(
      "CREATE INDEX phoenix_kit_consent_logs_session_type_idx ON #{schema}.phoenix_kit_consent_logs USING btree (session_id, consent_type)"
    )

    Repo.query!(
      "CREATE INDEX phoenix_kit_consent_logs_type_idx ON #{schema}.phoenix_kit_consent_logs USING btree (consent_type)"
    )

    Repo.query!(
      "CREATE INDEX phoenix_kit_consent_logs_user_uuid_idx ON #{schema}.phoenix_kit_consent_logs USING btree (user_uuid)"
    )
  end

  # The shape this package's own deleted pre-0.3.0 DDL copies produced —
  # dev_docs/reports/2026-08-10-module-migration-versioning.md's
  # divergence table: every varchar widened to Ecto's default (255), and
  # index names from neither core's nor this chain's naming scheme.
  defp create_legacy_table(schema) do
    Repo.query!("""
    CREATE TABLE #{schema}.phoenix_kit_consent_logs (
      uuid uuid DEFAULT gen_random_uuid() PRIMARY KEY,
      session_id character varying(255),
      consent_type character varying(255) NOT NULL,
      consent_given boolean NOT NULL DEFAULT false,
      consent_version character varying(255),
      ip_address character varying(255),
      user_agent_hash character varying(255),
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp with time zone NOT NULL DEFAULT now(),
      updated_at timestamp with time zone NOT NULL DEFAULT now(),
      user_uuid uuid
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX phoenix_kit_consent_logs_user_uuid_index ON #{schema}.phoenix_kit_consent_logs (user_uuid)"
    )

    Repo.query!(
      "CREATE INDEX phoenix_kit_consent_logs_session_id_index ON #{schema}.phoenix_kit_consent_logs (session_id)"
    )
  end
end
