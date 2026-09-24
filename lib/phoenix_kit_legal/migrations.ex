defmodule PhoenixKit.Modules.Legal.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_legal` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`. `phoenix_kit_projects` is the reference implementation;
  `phoenix_kit_document_creator` is the same shape over core-created
  tables, which is exactly this chain's situation.

  ## Ownership history — read before touching

  `phoenix_kit_consent_logs` was created by core's V43 (when Legal was
  still part of core) and today ships in core's squashed V135 baseline,
  so on every existing install the table predates this chain. 0.3.0/0.3.1
  briefly pinned the table as core-owned after this package had
  accumulated two DDL copies that drifted from core's and from each other
  (`dev_docs/reports/2026-08-10-module-migration-versioning.md`). This
  chain is the deliberate follow-up, not a relapse: ownership of the
  table's FUTURE shape moves here, and the drift class that caused the
  0.3.0 cleanup is killed at the root — every width in `up_statements/1`
  is read from `ConsentLog.column_widths/0`, this package's single width
  authority. There is no second copy of those numbers to disagree with.
  The division of labour with core is documented in
  `dev_docs/reports/2026-08-10-consent-logs-extraction.md`.

  ## What V1 is

  V1 is an ADOPTION step, not a create:

    * on existing installs the table is already there (core V135), the
      `CREATE TABLE IF NOT EXISTS` finds it, and the only new object is
      the `pkl_schema:1` marker — from then on this chain owns the
      table's future shape;
    * on a hypothetical future install whose core baseline no longer
      creates the table, the same statements create it — shape-identical
      to core's V135, with core's exact index and constraint names.

  Because V1 changes no shape, core's `ExpectedSchema` manifest (which
  still audits the V135 shape of this table) stays accurate and NO core
  release is required for this version. The first version that DOES
  change shape (V2+) must follow the excluded-object protocol described
  in the extraction report before it ships.

  ## Two owners, two independent audits

  Core's `ExpectedSchema` still lists `phoenix_kit_consent_logs` (owner:
  `:core`, `since: 43`) and `mix phoenix_kit.doctor`/`mix phoenix_kit.repair`
  verify a live database against that listing regardless of whether this
  chain has ever run. That is deliberate, not a conflict to resolve: core
  audits the table's PAST shape (the V135 baseline it created and still
  ships), this chain owns the table's FUTURE shape (V2+), and V1 is defined
  to be shape-identical to that baseline precisely so both audits agree on
  every existing install. Core's repair path has no knowledge of the
  `pkl_schema:` marker today — a different marker namespace serving a
  different question ("does this row match core's manifest?" vs. "has this
  module-owned chain adopted the table?") — and there is no commitment
  either way about whether a future core release changes that (a runtime
  module-ownership registry, if core ever builds one, would be the natural
  place). Neither doctor/repair nor this chain writes to the other's
  bookkeeping today, so a doctor run and an `up/1` run cannot step on each
  other's marker. The two stop agreeing only once a V2+ ships a real shape
  change here without also updating core's excluded-object list — which is
  exactly the protocol this moduledoc requires before that ships.

  ## Adoption verifies shape, not just existence

  V1's `CREATE TABLE IF NOT EXISTS` proves the table *exists*; it says
  nothing about whether the existing table's columns, widths, nullability,
  primary key and six indexes still match what this chain is about to claim
  ownership of by stamping `pkl_schema:1` (core issue #862: an adoption step
  built only from `IF NOT EXISTS` guards lets a hand-narrowed column, or a
  host that ran this package's pre-0.3.0 `varchar(255)` DDL copies, pass
  silently). Before `up/1` runs any statement, it reads the existing table's
  actual shape and compares it against the shape `up_statements/1` is about
  to (re-)create — parsed out of that same DDL by `parsed_expected_columns/1`,
  `parsed_expected_indexes/1` and `parsed_expected_primary_key/1`, so there is
  no independently hand-written copy of the canonical shape to drift from it
  (`PhoenixKit.Modules.Legal.Migrations.AdoptionShape.diff/2`). No existing
  column's type or width is ever changed automatically, in either mode below
  — this chain has no `ALTER COLUMN ... TYPE` statement anywhere, and
  narrowing a live column by hand is the operator's decision, never this
  migration's. `AdoptionShape.format/1`'s message spells out that manual
  procedure (check existing data against the canonical width before
  narrowing anything — `ALTER TABLE ... ALTER COLUMN ... TYPE character
  varying(N)` fails outright on over-length existing data, the same way a
  normal INSERT/UPDATE past the declared width does; neither truncates).

  A mismatch's outcome depends on `adoption_shape_check_mode/0`
  (`config :phoenix_kit_legal, :adoption_shape_check`, default `:raise`):

    * `:raise` raises `AdoptionShapeError` with the exact per-column/
      per-index diff before any statement in `up_statements/1` runs — so
      truly nothing executes. Nothing is written — no marker — and
      `Ecto.Migrator` never records this migration as applied, so a later
      `mix ecto.migrate`/`mix phoenix_kit.update` retries it (reusing the
      same generated migration file, not writing a new one) once the drift
      is reconciled by hand; no separate step needed beyond fixing the
      table.
    * `:warn` logs the same diff at `:error` level and then PROCEEDS —
      `up_statements/1` runs exactly as it always does, unmodified by the
      drift. That is NOT risk-free: its DO-block guard still runs
      `ALTER TABLE ... ADD CONSTRAINT ..._pkey PRIMARY KEY (uuid)` when no
      constraint by that exact name exists yet, and its six
      `CREATE INDEX IF NOT EXISTS` statements still run against whatever
      columns the divergent table actually has. Against most divergences
      (extra or differently-named indexes, a missing marker) these are
      genuinely additive and succeed, and the `pkl_schema:1` marker gets
      written despite the drift — deliberately: if it were withheld
      instead, this migration would stay pending forever and `mix
      phoenix_kit.update` would keep re-attempting the same reused
      migration file on every invocation rather than ever converging.
      Against some divergences, though, those same statements fail outright
      with a raw Postgres error rather than a marker write: an existing
      primary key under any OTHER name collides with the `ADD CONSTRAINT`
      (`42P16 multiple primary keys for table ... are not allowed`), and a
      table simply missing a column one of the six indexes references
      fails its `CREATE INDEX` (`42703 column ... does not exist`) — both
      reproduced directly against PostgreSQL. `:warn` softens "this table's
      drift blocks the host's other migrations" into "some shapes of this
      table's drift still do," not into "never."

  The default is `:raise`, not `:warn`, because this table is a GDPR/CCPA
  consent evidence trail: a `mix phoenix_kit.update` that stops outright is
  loud and immediately actionable, while a table silently adopted with
  unverified widths is exactly the kind of thing that goes unnoticed until
  a compliance question depends on it. A table that does not exist yet has
  nothing to compare against — `up/1` creates it fresh, which is canonical
  by construction, regardless of the configured mode.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops
  `phoenix_kit_consent_logs`. The rows are a GDPR/CCPA consent audit
  trail and, on most installs, the table is core-created — rolling back
  the module must not destroy either. The ownership test pins this by
  asserting no statement this module can emit matches `DROP`.

  The migrated version is tracked as a `pkl_schema:<N>` COMMENT on
  `phoenix_kit_consent_logs` (the marker convention from the projects
  chain, namespaced). A marker-less table reads as version 0 — the
  core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  require Logger

  alias PhoenixKit.Modules.Legal.ConsentLog
  alias PhoenixKit.Modules.Legal.Migrations.AdoptionShape
  alias PhoenixKit.Modules.Legal.Migrations.AdoptionShapeError

  @current_version 1
  @marker_prefix "pkl_schema:"
  @version_table "phoenix_kit_consent_logs"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkl_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkl_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the projects
    # chain's convention, via document_creator).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  Applies every chain version up to `current_version/0` (idempotent).

  Checks an EXISTING table's shape before running any statement below —
  see the moduledoc, "Adoption verifies shape, not just existence".
  `adoption_shape_check_mode/0` decides what a drift does: under the
  default `:raise`, `enforce_adoption_shape!/1` raises `AdoptionShapeError`
  here and nothing below ever runs. Under `:warn`, it logs and returns —
  `up_statements/1` still runs unconditionally after it, so the marker
  gets written either way unless `:raise` aborted first.
  """
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    :ok = enforce_adoption_shape!(prefix)

    prefix
    |> up_statements()
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops the table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test parses these statements to prove that every varchar
  width is `ConsentLog.column_widths/0`, that the object names are
  core's V135 names, and that nothing here can drop the table.
  """
  @spec up_statements(String.t()) :: [String.t()]
  def up_statements(prefix \\ "public") do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    w = ConsentLog.column_widths()

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}#{@version_table} (
        "session_id" character varying(#{w.session_id}),
        "consent_type" character varying(#{w.consent_type}) NOT NULL,
        "consent_given" boolean DEFAULT false NOT NULL,
        "consent_version" character varying(#{w.consent_version}),
        "ip_address" character varying(#{w.ip_address}),
        "user_agent_hash" character varying(#{w.user_agent_hash}),
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid
      )
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = '#{@version_table}_pkey'
            AND t.relname = '#{@version_table}'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}#{@version_table} ADD CONSTRAINT #{@version_table}_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_uuid_unique_index ON #{p}#{@version_table} USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS #{@version_table}_inserted_at_idx ON #{p}#{@version_table} USING btree (inserted_at)",
      "CREATE INDEX IF NOT EXISTS #{@version_table}_session_id_idx ON #{p}#{@version_table} USING btree (session_id)",
      "CREATE INDEX IF NOT EXISTS #{@version_table}_session_type_idx ON #{p}#{@version_table} USING btree (session_id, consent_type)",
      "CREATE INDEX IF NOT EXISTS #{@version_table}_type_idx ON #{p}#{@version_table} USING btree (consent_type)",
      "CREATE INDEX IF NOT EXISTS #{@version_table}_user_uuid_idx ON #{p}#{@version_table} USING btree (user_uuid)",
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{@current_version}'"
    ]
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0) do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  @doc """
  The raw column shape (`type` text as written in the DDL — width baked
  in, e.g. `"character varying(64)"` — plus `default` and `not_null`)
  `up_statements/1`'s `CREATE TABLE` declares for each of the 11 known
  columns, parsed back out of that same DDL text. The single source both
  the ownership test's full-shape comparison against core's manifest
  (which needs `default`, to catch a drifted default too) and
  `parsed_expected_columns/1` below (which decomposes `type` further, to
  compare against Postgres's own catalog shape) build on — there is no
  second regex over this text anywhere in this package.
  """
  @spec parsed_column_definitions(String.t()) :: %{
          String.t() => %{type: String.t(), default: String.t() | nil, not_null: boolean()}
        }
  def parsed_column_definitions(prefix \\ "public") do
    [create | _] = up_statements(prefix)

    ~r/^\s*"(\w+)"\s+(.+?),?$/m
    |> Regex.scan(create)
    |> Map.new(fn [_line, name, definition] -> {name, parse_column_definition(definition)} end)
  end

  @doc """
  The column shape `verify_adoption_shape/1` compares against Postgres's
  own `information_schema.columns` (bare `type`, `max_length`, `nullable`
  — the same three fields `actual_columns/1` reads), decomposed from
  `parsed_column_definitions/1` rather than restated.
  """
  @spec parsed_expected_columns(String.t()) :: %{String.t() => AdoptionShape.column_shape()}
  def parsed_expected_columns(prefix \\ "public") do
    prefix
    |> parsed_column_definitions()
    |> Map.new(fn {name, definition} -> {name, decompose_column(definition)} end)
  end

  @doc """
  The 6 indexes `up_statements/1` declares (name, uniqueness, indexed
  columns), parsed back out of its `CREATE INDEX`/`CREATE UNIQUE INDEX`
  statements — the same parser `actual_indexes/1` runs over Postgres's
  `pg_indexes.indexdef`, since both are syntactically compatible with one
  regex.
  """
  @spec parsed_expected_indexes(String.t()) :: [AdoptionShape.index_shape()]
  def parsed_expected_indexes(prefix \\ "public") do
    prefix
    |> up_statements()
    |> Enum.flat_map(&parse_index_statement/1)
  end

  @doc """
  The primary key columns `up_statements/1` declares (always `["uuid"]`
  for this table), parsed back out of its DO-block guard. `[]` if the DDL
  declared none (unreachable for this chain today, but keeps this
  function total rather than raising on a hypothetical future DDL edit).
  """
  @spec parsed_expected_primary_key(String.t()) :: [String.t()]
  def parsed_expected_primary_key(prefix \\ "public") do
    prefix
    |> up_statements()
    |> Enum.find_value([], &parse_primary_key_statement/1)
  end

  @doc """
  Compares `phoenix_kit_consent_logs`'s actual shape at `prefix` against the
  one `up_statements/1` is about to (re-)create — see the moduledoc,
  "Adoption verifies shape, not just existence". Returns `:ok` when the
  table is absent (nothing to compare against — `up_statements/1` creates
  it fresh and canonical) or its shape already matches; `{:drift, diffs}`
  otherwise. Never raises itself — `up/1` decides what a drift means via
  `adoption_shape_check_mode/0`.

  Read-only — catalog queries via `repo/0` (the migration runner's own
  connection, safe to call mid-migration; never a separate pool checkout).
  Never calls `execute/1`, so it stays invisible to
  `up_statements/1`/`down_statements/2` and to any test that inspects
  those builders rather than `up/1` itself.
  """
  @spec verify_adoption_shape(String.t()) :: :ok | {:drift, [AdoptionShape.diff_entry()]}
  def verify_adoption_shape(prefix) do
    if table_exists?(prefix) do
      expected = %{
        columns: parsed_expected_columns(prefix),
        indexes: parsed_expected_indexes(prefix),
        primary_key: parsed_expected_primary_key(prefix)
      }

      actual = %{
        columns: actual_columns(prefix),
        indexes: actual_indexes(prefix),
        primary_key: actual_primary_key_columns(prefix)
      }

      case AdoptionShape.diff(expected, actual) do
        [] -> :ok
        diffs -> {:drift, diffs}
      end
    else
      :ok
    end
  end

  @doc """
  How `up/1` responds to `verify_adoption_shape/1` returning `{:drift, _}`
  — see the moduledoc, "Adoption verifies shape, not just existence" for
  the full rationale. `:raise` (the default) or `:warn`, read from
  `config :phoenix_kit_legal, :adoption_shape_check`.

  Raises `ArgumentError` for anything else — a typo here (`:warning`, say)
  would otherwise surface as an opaque `CaseClauseError` deep inside
  `enforce_adoption_shape!/1`, on a table drift, which is exactly the
  moment an operator least wants to be debugging their own config instead
  of reading a diff.
  """
  @spec adoption_shape_check_mode() :: :raise | :warn
  def adoption_shape_check_mode do
    case Application.get_env(:phoenix_kit_legal, :adoption_shape_check, :raise) do
      mode when mode in [:raise, :warn] ->
        mode

      other ->
        raise ArgumentError,
              "config :phoenix_kit_legal, :adoption_shape_check must be :raise or " <>
                ":warn, got: #{inspect(other)}"
    end
  end

  # Always returns :ok — `up/1` proceeds to `up_statements/1`
  # unconditionally right after calling this, so the only way to stop it
  # is to raise here. Under `:raise` (default), a drift does exactly that
  # and `up_statements/1` never runs. Under `:warn`, a drift is logged and
  # this still returns :ok, so `up_statements/1` runs anyway and writes
  # the marker despite the drift — see the moduledoc for why that is the
  # deliberate behavior, not an oversight.
  @spec enforce_adoption_shape!(String.t()) :: :ok
  defp enforce_adoption_shape!(prefix) do
    case verify_adoption_shape(prefix) do
      :ok ->
        :ok

      {:drift, diffs} ->
        case adoption_shape_check_mode() do
          :raise -> raise AdoptionShapeError, diffs
          :warn -> Logger.error(AdoptionShape.format(diffs))
        end

        :ok
    end
  end

  defp table_exists?(prefix) do
    query = """
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'r'
    """

    case repo().query!(query, [prefix, @version_table]) do
      %{rows: [_ | _]} -> true
      _ -> false
    end
  end

  defp actual_columns(prefix) do
    query = """
    SELECT column_name, data_type, character_maximum_length, is_nullable
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    """

    query
    |> then(&repo().query!(&1, [prefix, @version_table]))
    |> Map.fetch!(:rows)
    |> Map.new(fn [name, type, max_length, nullable] ->
      {name, %{type: type, max_length: max_length, nullable: nullable == "YES"}}
    end)
  end

  defp actual_indexes(prefix) do
    query = "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2"

    query
    |> then(&repo().query!(&1, [prefix, @version_table]))
    |> Map.fetch!(:rows)
    |> Enum.flat_map(fn [indexdef] -> parse_index_statement(indexdef) end)
  end

  defp actual_primary_key_columns(prefix) do
    query = """
    SELECT a.attname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
    WHERE c.contype = 'p' AND t.relname = $2 AND n.nspname = $1
    ORDER BY k.ord
    """

    query
    |> then(&repo().query!(&1, [prefix, @version_table]))
    |> Map.fetch!(:rows)
    |> Enum.map(fn [name] -> name end)
  end

  defp parse_column_definition(definition) do
    {definition, not_null} =
      case String.replace_suffix(definition, " NOT NULL", "") do
        ^definition -> {definition, false}
        trimmed -> {trimmed, true}
      end

    case String.split(definition, " DEFAULT ", parts: 2) do
      [type] -> %{type: type, default: nil, not_null: not_null}
      [type, default] -> %{type: type, default: default, not_null: not_null}
    end
  end

  defp decompose_column(%{type: type, not_null: not_null}) do
    case Regex.run(~r/^(.+)\((\d+)\)$/, type) do
      [_, base_type, max_length] ->
        %{type: base_type, max_length: String.to_integer(max_length), nullable: !not_null}

      nil ->
        %{type: type, max_length: nil, nullable: !not_null}
    end
  end

  defp parse_index_statement(stmt) do
    case Regex.run(
           ~r/CREATE (UNIQUE )?INDEX(?: IF NOT EXISTS)? (\w+) ON [\w.]+ USING \w+ \(([^)]+)\)/,
           stmt
         ) do
      [_, unique, name, columns] ->
        [%{name: name, unique: unique != "", columns: split_columns(columns)}]

      nil ->
        []
    end
  end

  defp parse_primary_key_statement(stmt) do
    case Regex.run(~r/ADD CONSTRAINT \w+_pkey PRIMARY KEY \(([^)]+)\)/, stmt) do
      [_, columns] -> split_columns(columns)
      nil -> nil
    end
  end

  defp split_columns(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the projects chain uses.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
