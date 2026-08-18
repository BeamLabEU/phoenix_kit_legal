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
      # V1 runs on installs where core's V135 already created everything, so
      # every statement must be a no-op against an object that is already there.
      #
      # The filter below is what made this vacuous: degrade `up_statements/1` to
      # just its COMMENT and the loop runs zero times. Reproduced — three other
      # tests caught that degradation and this one stayed green. So the set is
      # asserted before it is iterated.
      #
      # Only total emptiness is defended here on purpose. A statement list that
      # shrank without emptying is caught by `V1 uses core's exact object
      # names`, which requires all seven of them; restating that count here
      # would be a second copy of the same invariant.
      ddl = Enum.reject(Migrations.up_statements(), &String.starts_with?(&1, "COMMENT"))

      refute ddl == [],
             "up_statements/1 emitted no DDL at all — there is nothing here to " <>
               "call idempotent, and without this assertion the test passes " <>
               "having inspected nothing"

      for stmt <- ddl do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end
  end

  describe "the chain can never destroy the audit trail" do
    # Compared against the WHOLE expected content, not scanned for a forbidden
    # substring. Three reasons, all learned the hard way:
    #
    #   * A substring check only sees statements the builder produced. Anything
    #     appended past it — a literal `execute("DROP TABLE ...")` in `up/1` —
    #     is invisible to it. (That path is closed by the test below this
    #     describe block, which checks what is executed rather than what is
    #     built.)
    #   * One surviving harmless statement satisfies both "not empty" and "no
    #     DROP" at once, so those two assertions together still allow every
    #     other statement to vanish.
    #   * Requiring the list to be non-empty forbids the safest legitimate
    #     outcome. Core created this table; V1 adopts it. A rollback that does
    #     nothing at all is correct here, and a test that demands rollback
    #     "do something" pushes the next maintainer exactly where not touching
    #     is safer. Under equality an empty rollback is an expected value to
    #     write down, not a violation to work around.
    #
    # For `down/1` the expected content is the full statement text: two lines,
    # so exactness is cheap and total.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_consent_logs IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_consent_logs IS 'pkl_schema:1'"]

      assert Migrations.down_statements("legal_alt", 0) ==
               ["COMMENT ON TABLE legal_alt.phoenix_kit_consent_logs IS NULL"]

      assert Migrations.down_statements("legal_alt", 2) ==
               ["COMMENT ON TABLE legal_alt.phoenix_kit_consent_logs IS 'pkl_schema:2'"]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather than
    # the full SQL text. Pasting nine statements here would put a second copy of
    # the DDL in the test suite, which is the defect this module spent 0.3.0
    # unwinding. An operation is `{verb, object}`, which is immune to
    # reformatting and still fails on any statement added, removed or retargeted
    # — including a destructive one, which cannot enter this set without
    # changing it.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_consent_logs"},
      {"DO", "phoenix_kit_consent_logs_pkey"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_consent_logs_uuid_unique_index"},
      {"CREATE INDEX", "phoenix_kit_consent_logs_inserted_at_idx"},
      {"CREATE INDEX", "phoenix_kit_consent_logs_session_id_idx"},
      {"CREATE INDEX", "phoenix_kit_consent_logs_session_type_idx"},
      {"CREATE INDEX", "phoenix_kit_consent_logs_type_idx"},
      {"CREATE INDEX", "phoenix_kit_consent_logs_user_uuid_idx"},
      {"COMMENT ON TABLE", "phoenix_kit_consent_logs"}
    ]

    test "up/1 emits exactly these operations and no others" do
      for prefix <- ["public", "legal_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a table core created
               and whose rows are a GDPR/CCPA consent audit trail. Adding one is a
               chain version (V2+) and belongs in the extraction report's protocol;
               it is not something to slip past this list.
               """
      end
    end

    # `{verb, object}` for one statement. The DO block is identified by the
    # constraint it adds, since its verb says nothing about its target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.starts_with?(normalized, "DO ") do
        [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
        {"DO", constraint}
      else
        [_, verb, object] =
          Regex.run(
            ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
            normalized
          )

        {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/1` and `down_statements/2`. The database
    # gets `up/1` and `down/1`. Nothing connected the two, so a literal
    # `execute("DROP TABLE ...")` written straight into `up/1` would have passed
    # every one of them — the guard was watching the data while the function did
    # the work.
    #
    # Checked against the source text, because this suite has no repo and cannot
    # run a migration. That pins the shape of the implementation, not just its
    # behaviour: rewriting `up/1` as a comprehension would fail this test even
    # though it still only executed the builder. That is the price of checking it
    # at all here, and it is the cheaper half of the trade — the alternative is
    # no check on the executed path.
    @source "lib/phoenix_kit_legal/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every statement this chain runs must come from up_statements/1 or
             down_statements/2, because those are what the tests above compare
             against their expected content. A statement executed directly is
             invisible to all of them — and this table's rows are a GDPR/CCPA
             consent audit trail.
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/1 into execute/1 — whatever it " <>
               "runs instead is not what `up/1 emits exactly these operations` checks"

      assert source =~ ~r/down_statements\(target\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end
  end

  test "no migration template is shipped in priv/" do
    # `priv/migrations/add_phoenix_kit_consent_logs.exs` was a copy-into-your-app
    # template the README pointed at, deleted in 0.3.0. Hosts migrate through
    # `mix phoenix_kit.update` (which discovers the chain) — never by copying
    # DDL by hand.
    priv = :code.priv_dir(:phoenix_kit_legal) |> to_string()

    # A glob over a path that does not resolve returns [], which satisfies the
    # assertion below without looking at anything. Reproduced by pointing `priv`
    # at a nonexistent directory: 16 tests, 0 failures. So the location is
    # proved before its emptiness is claimed — `legal_templates/` is content
    # this package definitely ships, and finding it means we are reading the
    # real priv dir.
    assert File.dir?(priv), "priv dir did not resolve: #{inspect(priv)}"

    assert Path.wildcard(Path.join([priv, "legal_templates", "*.eex"])) != [],
           """
           No templates found under #{priv}/legal_templates.

           This package ships them, so their absence means this test is reading
           the wrong directory — and the assertion below would then report "no
           migration templates" about a place that holds none of anything.
           """

    stray = Path.wildcard(Path.join([priv, "migrations", "*.exs"]))

    assert stray == [],
           """
           Migration templates found in priv/: #{inspect(stray)}

           The chain in PhoenixKit.Modules.Legal.Migrations is the only DDL
           source; hosts run `mix phoenix_kit.update`.
           """
  end

  describe "ConsentLog changeset guards the declared column widths" do
    # These assert Ecto's error METADATA, not its message text. The metadata
    # carries the limit — `[count: 64, validation: :length, kind: :max]` — so it
    # pins the number the column actually has; the human string does not mention
    # it, and changes when Ecto rewords, which would break these tests without
    # any behaviour changing. A test that fails on a reformulation and passes on
    # a changed limit is pinning the wrong thing.
    #
    # The limits come from `column_widths/0` rather than being written out, so
    # widening a column cannot leave these two disagreeing with it.
    test "rejects a session_id longer than varchar(64)" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: String.duplicate("a", 65)
        })

      refute changeset.valid?
      assert {_message, meta} = changeset.errors[:session_id]
      assert meta[:validation] == :length
      assert meta[:kind] == :max
      assert meta[:count] == ConsentLog.column_widths().session_id
    end

    test "rejects a consent_version longer than varchar(20)" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "necessary",
          session_id: "s",
          consent_version: String.duplicate("9", 21)
        })

      refute changeset.valid?
      assert {_message, meta} = changeset.errors[:consent_version]
      assert meta[:validation] == :length
      assert meta[:kind] == :max
      assert meta[:count] == ConsentLog.column_widths().consent_version
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
