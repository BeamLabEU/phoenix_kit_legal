defmodule PhoenixKit.Modules.Legal.ConsentLogsOwnershipTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.ConsentLog
  alias PhoenixKit.Modules.Legal.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_consent_logs`: this package owns
  the table's FUTURE shape through its module migration chain, while core's
  V135 baseline still creates the table on every install and the chain's V1
  merely ADOPTS it (stamps the `pkl_schema:` marker, changes no shape).

  History, in order — both reports live in `dev_docs/reports/`:

    * `2026-08-10-module-migration-versioning.md` — the package had
      accumulated two DDL copies of a core-created table, both drifted from
      core's and from each other; 0.3.0/0.3.1 deleted them and pinned the
      table as core-owned.
    * `2026-08-10-consent-logs-extraction.md` — the deliberate extraction that
      followed: a module-owned chain whose DDL is BUILT from
      `ConsentLog.column_widths/0`, so the drift class that forced the 0.3.0
      cleanup cannot recur. These tests are the pin.

  What must stay true:

    * exactly ONE DDL source in this package (`Migrations.up_statements/1`),
      and its widths ARE `ConsentLog.column_widths/0`;
    * the chain can never drop the table — the rows are a GDPR/CCPA consent
      audit trail, and on most installs the table is core-created;
    * V1 stays shape-identical to core's V135 baseline (core's
      `ExpectedSchema` audits that shape); the first shape-changing version
      must follow the excluded-object protocol in the extraction report.
  """

  test "Legal declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(Legal)

    assert Legal.migration_module() == Migrations,
           """
           PhoenixKit.Modules.Legal no longer declares its migration chain \
           (migration_module/0 returned #{inspect(Legal.migration_module())}).

           The chain is how the table's future shape is versioned (pkl_schema
           marker) and how `mix phoenix_kit.update` migrates hosts. Removing it
           reverts to the pre-extraction state — read
           dev_docs/reports/2026-08-10-consent-logs-extraction.md before doing
           that deliberately.
           """
  end

  describe "the coordinator implements the protocol" do
    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 1
      assert Migrations.version_table() == "phoenix_kit_consent_logs"
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain DDL is built from ConsentLog.column_widths/0" do
    # The one lesson of the three-DDLs incident: never a second copy of the
    # numbers. The CREATE is parsed back and compared width-by-width.
    test "every varchar width in the CREATE is the declared width" do
      [create | _] = Migrations.up_statements()

      parsed =
        Regex.scan(~r/"(\w+)" character varying\((\d+)\)/, create)
        |> Map.new(fn [_, col, width] -> {col, String.to_integer(width)} end)

      declared = Map.new(ConsentLog.column_widths(), fn {k, v} -> {Atom.to_string(k), v} end)

      assert parsed == declared,
             """
             The CREATE TABLE widths and ConsentLog.column_widths/0 disagree.

             parsed from DDL: #{inspect(parsed)}
             declared:        #{inspect(declared)}

             up_statements/1 must interpolate column_widths/0 — never restate
             a number.
             """
    end

    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      # Core V135's names, verbatim: the pkey and all six indexes.
      for name <- [
            "phoenix_kit_consent_logs_pkey",
            "phoenix_kit_consent_logs_uuid_unique_index",
            "phoenix_kit_consent_logs_inserted_at_idx",
            "phoenix_kit_consent_logs_session_id_idx",
            "phoenix_kit_consent_logs_session_type_idx",
            "phoenix_kit_consent_logs_type_idx",
            "phoenix_kit_consent_logs_user_uuid_idx"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V135"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_consent_logs IS 'pkl_schema:1'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V135 already created everything.
      for stmt <- Migrations.up_statements(), not String.starts_with?(stmt, "COMMENT") do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end
  end

  describe "the chain can never destroy the audit trail" do
    test "no statement in either direction matches DROP or TRUNCATE" do
      all =
        Migrations.up_statements() ++
          Migrations.down_statements("public", 0) ++
          Migrations.down_statements("public", 1)

      for stmt <- all do
        refute stmt =~ ~r/\b(DROP|TRUNCATE|DELETE)\b/i,
               """
               A chain statement can destroy phoenix_kit_consent_logs:

               #{stmt}

               The table is a GDPR/CCPA consent audit trail and on most installs
               it is core-created. down/1 unstamps the marker; nothing more.
               """
      end
    end

    test "down to 0 removes the marker; down to a version restamps it" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_consent_logs IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_consent_logs IS 'pkl_schema:1'"]
    end
  end

  test "no migration template is shipped in priv/" do
    # `priv/migrations/add_phoenix_kit_consent_logs.exs` was a copy-into-your-app
    # template the README pointed at, deleted in 0.3.0. Hosts migrate through
    # `mix phoenix_kit.update` (which discovers the chain) — never by copying
    # DDL by hand.
    priv = :code.priv_dir(:phoenix_kit_legal) |> to_string()
    stray = Path.wildcard(Path.join([priv, "migrations", "*.exs"]))

    assert stray == [],
           """
           Migration templates found in priv/: #{inspect(stray)}

           The chain in PhoenixKit.Modules.Legal.Migrations is the only DDL
           source; hosts run `mix phoenix_kit.update`.
           """
  end

  describe "ConsentLog changeset guards the declared column widths" do
    test "rejects a session_id longer than varchar(64)" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: String.duplicate("a", 65)
        })

      refute changeset.valid?
      assert {"should be at most %{count} character(s)", _} = changeset.errors[:session_id]
    end

    test "rejects a consent_version longer than varchar(20)" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: "s",
          consent_version: String.duplicate("9", 21)
        })

      refute changeset.valid?
      assert {"should be at most %{count} character(s)", _} = changeset.errors[:consent_version]
    end

    test "accepts values at exactly the limits" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: String.duplicate("a", 64),
          consent_version: String.duplicate("9", 20),
          ip_address: String.duplicate("f", 45),
          user_agent_hash: String.duplicate("0", 64)
        })

      assert changeset.valid?
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the table)" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Core's V135 baseline still creates this table and core's ExpectedSchema
    # audits that shape, so until the first shape-changing chain version the
    # two DDLs must agree.
    #
    # The invariant is PER FIELD, and that matters more than it looks. An
    # earlier version of this test collected core's widths into a map and
    # compared under `core != nil`, which silently dropped every field whose
    # key was absent — so a parse that stopped matching some of core's columns
    # left the test green with however many comparisons happened to survive.
    # Checking that the map was non-empty did not fix it: one width out of
    # eleven is non-empty. Partial breakage is both likelier than total and
    # quieter — a column added in another DDL spelling, a case change — so the
    # missing key has to fail the field, not skip it.
    #
    # Core no longer declaring a column AT ALL stays benign: that is the
    # documented empty for a V2+ excluded object, or a future core that stops
    # naming the table. `core_columns/0` is what decides that, and the widths
    # are derived from the same map, so both sides are keyed by bare column
    # name and there is one parse to break instead of two drifting ones.
    #
    # Two residues of that choice, named so the next reader does not have to
    # rediscover them:
    #
    #   * If `core_columns/0` itself returns nothing — core renames the object
    #     id format, say — this test passes empty, because every field is then
    #     legitimately "not declared". The guard in that case is
    #     `every column core declares matches V1's, in full`, which reads the
    #     same map and asserts set equality with V1's own columns, so an empty
    #     core side fails there. One shared source is why that works; it is
    #     also why this test cannot be the one to catch it.
    #   * A field in `column_widths/0` whose name does not match its column
    #     name would drop out of the comparison silently. They are one-to-one
    #     today, so this is theoretical — but the mapping is `Atom.to_string/1`
    #     and nothing asserts it.
    test "every width core declares is the width this package declares" do
      core = core_columns()
      widths = core_varchar_widths()

      for {field, declared} <- ConsentLog.column_widths() do
        name = Atom.to_string(field)

        if Map.has_key?(core, name) do
          assert Map.has_key?(widths, name),
                 """
                 #{name}: core's manifest declares this column, but no varchar \
                 width could be read from it.

                 Its declared type is #{inspect(get_in(core, [name, :type]))}.

                 Either the type spelling this test parses has changed — fix the
                 parse, do not let the field fall out of the comparison — or core
                 has changed the column away from varchar, which this package
                 still length-validates at #{declared} and must stop doing.
                 """

          assert Map.fetch!(widths, name) == declared,
                 """
                 #{name}: this package declares max #{declared}, core's manifest \
                 declares #{Map.fetch!(widths, name)}.

                 V1 must stay shape-identical to core's baseline. A deliberate
                 width change is a chain version (V2+) and follows the
                 excluded-object protocol in
                 dev_docs/reports/2026-08-10-consent-logs-extraction.md.
                 """
        end
      end
    end

    # Widths are only the part of the shape that has a number in it. "V1
    # changes no shape" also covers which columns exist, their types, their
    # defaults and their nullability — and the width check above passes
    # happily while any of those drift. That is the same blind spot the
    # three-DDLs incident had: the copies agreed where somebody had thought to
    # compare them.
    #
    # The manifest carries all of it, so compare all of it. `create` omits
    # NOT NULL for columns core backfills separately (inserted_at,
    # updated_at), so nullability comes from the latest revision, which is the
    # shape a migrated database ends up in.
    test "every column core declares matches V1's, in full" do
      core = core_columns()
      ours = v1_columns()

      assert Map.keys(ours) -- Map.keys(core) == [],
             "V1 creates columns core's manifest does not declare: " <>
               inspect(Map.keys(ours) -- Map.keys(core))

      assert Map.keys(core) -- Map.keys(ours) == [],
             "V1 does not create columns core's manifest declares: " <>
               inspect(Map.keys(core) -- Map.keys(ours))

      for {column, expected} <- core do
        assert Map.fetch!(ours, column) == expected,
               """
               #{column}: V1 and core's manifest disagree on the column's shape.

               V1:              #{inspect(Map.fetch!(ours, column))}
               core's manifest: #{inspect(expected)}

               V1 is an adoption and must be shape-identical to core's
               baseline. A deliberate change is a chain version (V2+) and
               follows the excluded-object protocol in
               dev_docs/reports/2026-08-10-consent-logs-extraction.md.
               """
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision.
    defp core_columns do
      ExpectedSchema.objects("public")
      |> Enum.filter(
        &(&1.class == :column and
            String.starts_with?(&1.id, "column:phoenix_kit_consent_logs."))
      )
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, "column:phoenix_kit_consent_logs.", ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # Widths read out of the very same map `core_columns/0` returns, so the
    # width comparison and the full-shape comparison cannot disagree about
    # which columns core declares or how they are keyed.
    defp core_varchar_widths do
      core_columns()
      |> Enum.flat_map(fn {name, %{type: type}} ->
        case Regex.run(~r/character varying\((\d+)\)/, type) do
          [_, width] -> [{name, String.to_integer(width)}]
          nil -> []
        end
      end)
      |> Map.new()
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits.
    defp v1_columns do
      [create | _] = Migrations.up_statements()

      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp parse_column(definition) do
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
  end

  describe "producers respect the declared widths" do
    test "update_policy_version/1 rejects a version the column cannot hold" do
      # The policy version becomes `consent_version` on every logged consent
      # (get_consent_widget_config/0 -> widget -> ConsentLog). Storing an
      # over-long one succeeds and then fails every consent write afterwards,
      # far from the setting that caused it.
      too_long = String.duplicate("v", 21)

      assert {:error, :version_too_long} = Legal.update_policy_version(too_long)
    end
  end
end
