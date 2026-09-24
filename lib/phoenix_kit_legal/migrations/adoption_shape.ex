defmodule PhoenixKit.Modules.Legal.Migrations.AdoptionShapeError do
  @moduledoc """
  Raised by `PhoenixKit.Modules.Legal.Migrations.up/1`, under the default
  `adoption_shape_check_mode/0` (`:raise`), when an EXISTING
  `phoenix_kit_consent_logs` diverges from the canonical shape — see
  `PhoenixKit.Modules.Legal.Migrations.AdoptionShape`. Raising happens
  before any statement in `up_statements/1` executes, so no DDL runs and
  the `pkl_schema:1` marker is never written; `Ecto.Migrator` never
  records this migration as applied either, so a later `mix ecto.migrate`
  retries it once the shape is reconciled. Under `:warn` mode, the same
  diff is logged at `:error` level instead and `up/1` proceeds —
  `up_statements/1` runs and DOES write the marker despite the drift, so
  this exception is never raised in that mode — see
  `Migrations.adoption_shape_check_mode/0`.
  """
  alias PhoenixKit.Modules.Legal.Migrations.AdoptionShape

  defexception [:message, :diffs]

  @impl true
  def exception(diffs) do
    %__MODULE__{message: AdoptionShape.format(diffs), diffs: diffs}
  end
end

defmodule PhoenixKit.Modules.Legal.Migrations.AdoptionShape do
  @moduledoc """
  What `phoenix_kit_consent_logs` must look like before
  `PhoenixKit.Modules.Legal.Migrations` V1 is allowed to stamp the
  `pkl_schema:1` adoption marker on an EXISTING table.

  Core issue #862 names the class of bug this module closes: a
  `CREATE TABLE IF NOT EXISTS` adoption step checks that an object
  *exists*, never that its *shape* matches what the chain is about to
  claim ownership of. A column narrowed by hand outside migrations, or a
  host that ran one of this package's own pre-0.3.0 DDL copies
  (`dev_docs/reports/2026-08-10-module-migration-versioning.md` — the
  `varchar(255)` shape), would otherwise survive adoption silently: exit
  0, marker written, no rows lost, and the marker now asserts a shape
  nothing ever verified.

  `diff/2` is the pure comparison — both `expected` and `actual` are
  plain data the caller already assembled, so it is testable without a
  database. Deliberately, this module hand-writes NEITHER shape: the
  `expected` side always comes from `Migrations.parsed_expected_columns/1`,
  `parsed_expected_indexes/1` and `parsed_expected_primary_key/1` —
  parsed out of `up_statements/1` itself, the same DDL this chain
  actually runs — never a second, independently-maintained copy of the
  column widths/types/index names/pk that could drift from it the way
  this package's three pre-0.3.0 DDL copies did. The only non-pure part
  of the check (`Migrations.verify_adoption_shape/1`) is a handful of
  read-only catalog queries plus a call to this function.

  This module is pure — it never proposes or runs any SQL, `ALTER` included
  (see `Migrations.up/1`'s moduledoc for what its caller does with a
  divergence instead). A normal `INSERT`/`UPDATE` that exceeds a column's
  declared width, and `ALTER TABLE ... ALTER COLUMN ... TYPE character
  varying(N)` against existing data that already exceeds `N`, both fail
  outright (`value too long for type character varying(N)`) rather than
  truncating; only an explicit cast (`::character varying(N)`) truncates
  without error. Deciding whether existing data needs
  reconciling before narrowing a column is still an operator's call, never
  this migration's, so the only two outcomes of a mismatch are "adopt" or
  "refuse with an exact diff and a manual procedure" — never "coerce".
  """

  @typedoc "A column's shape as both `information_schema.columns` and `Migrations.parsed_expected_columns/1` report it."
  @type column_shape :: %{
          type: String.t(),
          max_length: pos_integer() | nil,
          nullable: boolean()
        }

  @typedoc "An index's shape as both `pg_indexes` and `Migrations.parsed_expected_indexes/1` report it."
  @type index_shape :: %{name: String.t(), unique: boolean(), columns: [String.t()]}

  @typedoc "The full comparable shape of `phoenix_kit_consent_logs`."
  @type shape :: %{
          columns: %{String.t() => column_shape()},
          indexes: [index_shape()],
          primary_key: [String.t()]
        }

  @type diff_entry ::
          {:missing_column, String.t()}
          | {:column_mismatch, String.t(), expected: column_shape(), actual: column_shape()}
          | {:missing_index, String.t()}
          | {:index_mismatch, String.t(), expected: index_shape(), actual: index_shape()}
          | {:primary_key_mismatch, expected: [String.t()], actual: [String.t()]}

  @doc """
  Compares an EXISTING table's actual shape against the canonical one.

  Returns `[]` when the table may be safely adopted (stamped with the
  marker); a non-empty list of `diff_entry/0` otherwise. Callers pass what
  they read from Postgres's catalogs as `actual`, and what
  `Migrations.parsed_expected_columns/1` + friends parsed out of
  `up_statements/1` as `expected` — this function does no I/O and knows
  nothing about prefixes, connections or the migration runner.

  Checks, per column: type and nullability. Deliberately never `default` —
  considered and declined: its textual representation varies harmlessly
  across schema-qualification and Postgres-version rendering (e.g.
  `uuid_generate_v7()` vs. `public.uuid_generate_v7()` for the exact same
  default, depending on how the catalog happens to render it), which would
  produce a false-positive drift on a live, perfectly healthy host; and no
  default drift can narrow or lose data the way a width or nullability
  drift can, so the false-positive risk buys no additional data-safety
  coverage. Per index: presence by name, uniqueness, and indexed columns.
  For the primary key: its column list.
  A column present in `actual` but absent from `expected` is never
  reported — V1 only owns the columns it declares.
  """
  @spec diff(shape(), shape()) :: [diff_entry()]
  def diff(expected, actual) do
    diff_columns(expected.columns, actual.columns) ++
      diff_indexes(expected.indexes, actual.indexes) ++
      diff_primary_key(expected.primary_key, actual.primary_key)
  end

  defp diff_columns(expected, actual) do
    Enum.flat_map(expected, fn {name, expected_shape} ->
      case Map.fetch(actual, name) do
        :error ->
          [{:missing_column, name}]

        {:ok, ^expected_shape} ->
          []

        {:ok, actual_shape} ->
          [{:column_mismatch, name, expected: expected_shape, actual: actual_shape}]
      end
    end)
  end

  defp diff_indexes(expected, actual) do
    actual_by_name = Map.new(actual, &{&1.name, &1})

    Enum.flat_map(expected, fn %{name: name} = expected_index ->
      case Map.fetch(actual_by_name, name) do
        :error ->
          [{:missing_index, name}]

        {:ok, ^expected_index} ->
          []

        {:ok, actual_index} ->
          [{:index_mismatch, name, expected: expected_index, actual: actual_index}]
      end
    end)
  end

  defp diff_primary_key(columns, columns), do: []

  defp diff_primary_key(expected, actual) do
    [{:primary_key_mismatch, expected: expected, actual: actual}]
  end

  @doc """
  Renders `diff/2`'s output as the text of `AdoptionShapeError` and, under
  `:warn` mode, as the `Logger.error/1` line logged in its place — both
  need the same content, so both go through this one function. Since this
  text is used both ways, it explains what EACH mode does with it rather
  than assuming which one produced it.
  """
  @spec format(nonempty_list(diff_entry())) :: String.t()
  def format(diffs) when is_list(diffs) and diffs != [] do
    lines = Enum.map(diffs, &format_entry/1)

    """
    phoenix_kit_consent_logs already exists and does not match the shape \
    phoenix_kit_legal is about to adopt:

    #{Enum.join(lines, "\n")}

    No existing column's type or width is ever changed automatically — \
    narrowing a column by hand is the operator's call, not this chain's. \
    ALTER TABLE ... ALTER COLUMN ... TYPE character varying(N) fails \
    outright ("value too long for type character varying(N)") if any \
    existing value exceeds N, the same way a normal INSERT/UPDATE would — \
    check first so the ALTER doesn't fail partway through.

    To reconcile by hand:
      1. Each line above names a column or index and both its expected and \
    actual shape.
      2. Before narrowing any column, check whether existing data already \
    exceeds the canonical width, e.g. for a column reported above:
           SELECT count(*) FROM phoenix_kit_consent_logs WHERE length(<column>) > <expected width>;
         A non-zero count means the ALTER below will fail as written — \
    decide what to do with those rows first (shorten them, remove them, or \
    leave the drift and use :warn mode instead of narrowing at all).
      3. Bring each column/index/primary key to the shape shown above by \
    hand (ALTER TABLE ... ALTER COLUMN ... TYPE character varying(N), or \
    DROP/CREATE INDEX to match the definitions above).

    mix phoenix_kit.doctor independently reports the same structural \
    divergence against core's own manifest (types and widths — it has no \
    knowledge of this marker) — useful as a second opinion, not a fix.

    What happens next depends on the configured \
    `adoption_shape_check_mode/0`. Under the default :raise, this is \
    raised as AdoptionShapeError BEFORE any of the statements above run — \
    the pkl_schema:1 marker is NOT written, and Ecto.Migrator does not \
    record this migration as applied, so a later mix ecto.migrate / mix \
    phoenix_kit.update retries it (reusing the migration file already \
    generated, not writing a new one) automatically once the shape above \
    is reconciled — no extra step needed beyond fixing the table. Under \
    `config :phoenix_kit_legal, :adoption_shape_check, :warn`, this is \
    logged at :error level instead and the migration PROCEEDS to run its \
    normal statements against this table anyway — not risk-free: adding \
    a missing primary key or a missing index can itself fail outright \
    (a primary key under any other name already present: "42P16 multiple \
    primary keys"; a referenced column entirely absent: "42703 column ... \
    does not exist") rather than completing. Where those statements DO \
    succeed, the marker gets written despite the drift, this check will \
    NOT run again automatically, and reconciling the shape stays a manual \
    fix at your own pace, informed by this log (mix phoenix_kit.doctor \
    keeps reporting the same divergence in the meantime). :warn turns \
    "this table's drift blocks the host's other migrations" into "SOME \
    shapes of this table's drift still do" — not into "none do"; the \
    default is :raise because a stopped migration is loud and immediately \
    actionable, while a consent-log table silently adopted with unverified \
    widths is a compliance risk nobody would notice until it mattered.
    """
  end

  defp format_entry({:missing_column, name}), do: "  - #{name}: column is missing"

  defp format_entry({:column_mismatch, name, expected: expected, actual: actual}) do
    "  - #{name}: expected #{describe_column(expected)}, found #{describe_column(actual)}"
  end

  defp format_entry({:missing_index, name}), do: "  - #{name}: index is missing"

  defp format_entry({:index_mismatch, name, expected: expected, actual: actual}) do
    "  - #{name}: expected #{describe_index(expected)}, found #{describe_index(actual)}"
  end

  defp format_entry({:primary_key_mismatch, expected: expected, actual: actual}) do
    "  - primary key: expected on #{inspect(expected)}, found on #{inspect(actual)}"
  end

  defp describe_column(%{type: type, max_length: nil, nullable: nullable}) do
    "#{type}#{null_suffix(nullable)}"
  end

  defp describe_column(%{type: type, max_length: max_length, nullable: nullable}) do
    "#{type}(#{max_length})#{null_suffix(nullable)}"
  end

  defp describe_index(%{unique: unique, columns: columns}) do
    "#{unique_label(unique)} on #{inspect(columns)}"
  end

  defp unique_label(true), do: "unique index"
  defp unique_label(false), do: "index"

  defp null_suffix(true), do: ""
  defp null_suffix(false), do: " NOT NULL"
end
