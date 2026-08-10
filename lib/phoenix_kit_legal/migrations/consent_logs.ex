defmodule PhoenixKit.Modules.Legal.Migrations.ConsentLogs do
  @moduledoc """
  Versioned migration coordinator for `phoenix_kit_consent_logs`, the one table
  this module owns.

  ## Versions

    * `0` — table absent.
    * `1` — table present. Two shapes exist in the wild, see below.
    * `2` — the two V1 shapes reconciled: widened `session_id`/`consent_type`/
      `consent_version`, `metadata` non-null, one canonical index set, and a
      numeric version marker in the table comment.

  ## Why V1 has two shapes

  Core's `PhoenixKit.Migrations.Postgres` V43 creates this table too, and Core's
  chain runs before module migrations in `mix phoenix_kit.update`. Every host
  therefore received the table from Core, with Core's column widths and index
  names — this module's `up/1` has never executed anywhere. V2 is the step that
  converges both shapes, and it is written to reach the same end state from
  either starting point.

  V1's DDL was corrected rather than frozen, which is normally forbidden — a
  shipped version step must stay immutable, because hosts already past it never
  re-run it. The exception is sound here precisely because no host is past it:
  Core's chain reaches V43 long before any release this module supports, so
  `up_v1/1` was unreachable code. Do not take this as licence to edit `up_v2/1`
  once it ships.

  ## The protocol

  `mix phoenix_kit.update` reads `migrated_version_runtime/1` and
  `current_version/0`, and when the database is behind it writes a migration into
  the host app calling `up(prefix:, version: target)` — and `down(prefix:,
  version: current)` for rollback, where `version` is the version to *return to*.

  The version is read from a `COMMENT ON TABLE`, never inferred from the table's
  existence: existence can only distinguish 0 from non-zero, which is not enough
  the moment a second version exists. Reading it back tolerates a non-numeric
  comment — Core's V43 left a prose description there — and treats it as V1,
  since a table that exists at all is at least V1.

  That prose description is replaced by the version marker at V2. The table's
  documentation lives in `AGENTS.md`, "Database Table", which says more than the
  one-line comment did.

  `up/1` re-reads the stored version itself instead of trusting the `version:` it
  was handed, so a stale or failed reading upstream costs a redundant migration
  file, never wrong DDL.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @initial_version 1
  @current_version 2
  @default_prefix "public"
  @version_table "phoenix_kit_consent_logs"

  # Canonical index set: Core's V43 names AND Core's exact definitions, because
  # those are the ones every existing host already carries. Adopting them means
  # V2 creates nothing on a Core-created table and only has to drop this module's
  # never-deployed `idx_consent_logs_*` names where they somehow exist.
  #
  # The definitions have to match Core's too, not just the names. `CREATE INDEX
  # IF NOT EXISTS` matches on name alone, so specifying `(inserted_at DESC)`
  # here would silently apply to fresh installs and be skipped on every
  # upgraded host — re-creating the two-shapes divergence this step exists to
  # remove. Core's is `btree (inserted_at)`, so this is too; a plain btree
  # serves `ORDER BY inserted_at DESC` by scanning backwards anyway.
  @indexes [
    {"phoenix_kit_consent_logs_user_uuid_idx", "(user_uuid)"},
    {"phoenix_kit_consent_logs_session_id_idx", "(session_id)"},
    {"phoenix_kit_consent_logs_type_idx", "(consent_type)"},
    {"phoenix_kit_consent_logs_inserted_at_idx", "(inserted_at)"},
    {"phoenix_kit_consent_logs_session_type_idx", "(session_id, consent_type)"}
  ]

  @legacy_indexes [
    "idx_consent_logs_user_uuid",
    "idx_consent_logs_session_id",
    "idx_consent_logs_consent_type",
    "idx_consent_logs_inserted_at"
  ]

  @doc "The schema version this code expects."
  def current_version, do: @current_version

  @doc "The first schema version, i.e. the version a bare table is at."
  def initial_version, do: @initial_version

  @doc """
  The table carrying the version marker in its `COMMENT`.

  Not part of the protocol Core calls. Exposed so an external auditor can check
  that the marker is actually a number without hard-coding this module's table
  name — the check that would have caught the version-inference defect described
  in `dev_docs/reports/2026-08-10-module-migration-versioning.md`.
  """
  def version_table, do: @version_table

  @doc """
  Applies every step up to and including the target version.

  `opts` accepts `:prefix` and `:version`; a map is accepted as well as a keyword
  list, for callers predating the keyword form.
  """
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 -> change(@initial_version..opts.version, :up, opts)
      initial < opts.version -> change((initial + 1)..opts.version, :up, opts)
      true -> :ok
    end

    :ok
  end

  @doc """
  Rolls back down to the target version.

  `version: 0` (the default when unspecified) removes the table. Any higher
  target keeps it: `down(version: 1)` means *return to V1*, not *drop*.
  """
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)
    current = migrated_version(opts)
    target = opts.version

    if current > target, do: change(current..(target + 1)//-1, :down, opts)

    :ok
  end

  @doc """
  Currently applied version, read in migration context.

  Raises if the database cannot answer — inside a migration, an unreadable
  version must abort the transaction rather than be guessed at.
  """
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  Currently applied version, read outside migration context.

  This is the one `mix phoenix_kit.update` calls, from a Mix task with no
  migrator running, so it resolves the repo through `PhoenixKit.RepoHelper`.

  An invalid prefix is re-raised rather than swallowed, matching Core's reader
  (`PhoenixKit.Migrations.Postgres.migrated_version_runtime/1`): reporting 0 for
  a bad prefix would tell the operator the module is not installed. Other
  failures — no connection, no privileges — do fall back to 0, which costs a
  redundant generated migration and nothing else, since `up/1` re-reads the
  version in migration context before touching anything.
  """
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  # ── v1 ────────────────────────────────────────────────────────────────────

  defp up_v1(prefix) do
    # Don't assume Core's chain created the function, and don't call it bare:
    # on a named-schema install it lives in that schema and an unqualified call
    # depends on the connecting role's search_path. `uuid_generate_v7()` is built
    # on pgcrypto's `gen_random_bytes`, and `ensure_uuid_v7_function/1` does not
    # install extensions — without this line the function is created and then
    # fails on first insert.
    Helpers.ensure_extension!("pgcrypto")
    Helpers.ensure_uuid_v7_function(prefix)

    table = Helpers.qualify_table(@version_table, prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{table} (
      uuid UUID PRIMARY KEY DEFAULT #{Helpers.uuid_v7_call(prefix)},
      user_uuid UUID,
      session_id VARCHAR(255),
      consent_type VARCHAR(50) NOT NULL,
      consent_given BOOLEAN NOT NULL DEFAULT false,
      consent_version VARCHAR(50),
      ip_address VARCHAR(45),
      user_agent_hash VARCHAR(64),
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    create_indexes(prefix)
  end

  defp down_v1(prefix) do
    execute("DROP TABLE IF EXISTS #{Helpers.qualify_table(@version_table, prefix)} CASCADE")
  end

  # ── v2 ────────────────────────────────────────────────────────────────────

  # Reconciles a Core-V43-created table with the shape above. Every statement is
  # a no-op against a table this module created at V1, so both paths converge.
  defp up_v2(prefix) do
    table = Helpers.qualify_table(@version_table, prefix)

    # Widening a varchar is a catalogue-only change in Postgres — no rewrite,
    # no lock beyond the ALTER itself, and no risk to stored values.
    execute("ALTER TABLE #{table} ALTER COLUMN session_id TYPE VARCHAR(255)")
    execute("ALTER TABLE #{table} ALTER COLUMN consent_type TYPE VARCHAR(50)")
    execute("ALTER TABLE #{table} ALTER COLUMN consent_version TYPE VARCHAR(50)")

    # V43 left metadata nullable; the schema and every writer treat it as a map.
    #
    # Operationally this is the expensive part of V2: the backfill writes every
    # row that still has NULL, and `SET NOT NULL` scans the whole table under an
    # ACCESS EXCLUSIVE lock. On a consent log with millions of rows, budget for
    # that — the rest of this step is catalogue-only.
    execute("UPDATE #{table} SET metadata = '{}'::jsonb WHERE metadata IS NULL")
    execute("ALTER TABLE #{table} ALTER COLUMN metadata SET DEFAULT '{}'::jsonb")
    execute("ALTER TABLE #{table} ALTER COLUMN metadata SET NOT NULL")

    Enum.each(@legacy_indexes, fn name ->
      execute("DROP INDEX IF EXISTS #{qualify_index(name, prefix)}")
    end)

    create_indexes(prefix)
  end

  # Deliberately partial. Dropping NOT NULL is reversible; narrowing the columns
  # back is not — it fails outright on any row already holding a longer value —
  # and which index set to restore is unknowable, since both V1 shapes exist.
  # A rollback that silently truncates data would be worse than one that leaves
  # the schema wider than it found it.
  defp down_v2(prefix) do
    table = Helpers.qualify_table(@version_table, prefix)
    execute("ALTER TABLE #{table} ALTER COLUMN metadata DROP NOT NULL")
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp create_indexes(prefix) do
    table = Helpers.qualify_table(@version_table, prefix)

    # Index names stay bare on CREATE — `CREATE INDEX schema.name` is a syntax
    # error; an index is scoped to its table's schema automatically.
    Enum.each(@indexes, fn {name, columns} ->
      execute("CREATE INDEX IF NOT EXISTS #{name} ON #{table} #{columns}")
    end)
  end

  defp change(range, direction, opts) do
    Enum.each(range, &apply_step(direction, &1, opts.prefix))

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, max(Enum.min(range) - 1, 0))
    end
  end

  defp apply_step(:up, 1, prefix), do: up_v1(prefix)
  defp apply_step(:up, 2, prefix), do: up_v2(prefix)
  defp apply_step(:down, 2, prefix), do: down_v2(prefix)
  defp apply_step(:down, 1, prefix), do: down_v1(prefix)

  defp apply_step(direction, version, _prefix) do
    raise ArgumentError, "no #{direction} step defined for schema version #{version}"
  end

  # Version 0 means the table is gone — nothing left to comment on.
  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute("COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = Map.get(opts, :prefix) || @default_prefix

    # The prefix reaches interpolated DDL below, and an invalid one must fail
    # loudly rather than be reported as "not installed".
    Helpers.validate_prefix!(prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  # Reads go through bound parameters rather than interpolation, so the prefix
  # cannot reach the query text even if validation is ever loosened.
  defp read_version(repo, prefix) do
    if table_exists?(repo, prefix) do
      repo
      |> table_comment(prefix)
      |> parse_version()
    else
      0
    end
  end

  defp table_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1 AND table_schema = $2
    )
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, error} -> raise error
    end
  end

  defp table_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  # A numeric comment is the version marker. Anything else on an existing table
  # is Core V43's prose description (or no comment at all, from a table this
  # module created at V1) — both mean V1. `Integer.parse/1` rather than
  # `String.to_integer/1`: the latter raises on prose, and a raise here would be
  # swallowed into "not installed" by the runtime reader's rescue.
  defp parse_version(comment) when is_binary(comment) do
    case Integer.parse(String.trim(comment)) do
      {version, ""} -> version
      _ -> @initial_version
    end
  end

  defp parse_version(_), do: @initial_version

  defp qualify_index(name, prefix) do
    if Helpers.public_prefix?(prefix), do: name, else: "#{prefix}.#{name}"
  end
end
