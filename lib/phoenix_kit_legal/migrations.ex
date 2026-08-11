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

  alias PhoenixKit.Modules.Legal.ConsentLog

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

  @doc "Applies every chain version up to `current_version/0` (idempotent)."
  def up(opts \\ []) do
    opts
    |> validated_prefix()
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
