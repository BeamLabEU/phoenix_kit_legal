defmodule PhoenixKit.Modules.Legal.Migrations.AdoptionShapeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pure unit tests for `Migrations.parsed_expected_columns/1` +
  `parsed_expected_indexes/1` + `parsed_expected_primary_key/1` (parsing
  the canonical shape out of `up_statements/1`) and `AdoptionShape.diff/2`
  (the comparison) — the pair core issue #862 is about: an adoption step
  that verifies existence (`IF NOT EXISTS`) but never shape.

  No database involved; every `actual` shape here is data a caller would
  have read from `information_schema.columns` / `pg_indexes` /
  `pg_constraint` — see
  `test/phoenix_kit_legal/migrations/adoption_integration_test.exs` for
  the same scenarios proven against a real PostgreSQL catalog. `expected`
  is always the REAL parse of `up_statements/1` (never a hand-written
  second copy) — see the moduledoc on `AdoptionShape`.
  """

  alias PhoenixKit.Modules.Legal.Migrations
  alias PhoenixKit.Modules.Legal.Migrations.AdoptionShape

  @expected_index_names [
    "phoenix_kit_consent_logs_uuid_unique_index",
    "phoenix_kit_consent_logs_inserted_at_idx",
    "phoenix_kit_consent_logs_session_id_idx",
    "phoenix_kit_consent_logs_session_type_idx",
    "phoenix_kit_consent_logs_type_idx",
    "phoenix_kit_consent_logs_user_uuid_idx"
  ]

  defp expected_shape do
    %{
      columns: Migrations.parsed_expected_columns(),
      indexes: Migrations.parsed_expected_indexes(),
      primary_key: Migrations.parsed_expected_primary_key()
    }
  end

  # A canonical `actual` shape is just the SAME data an unmodified table
  # would report back — expected.columns already has the right shape for
  # `actual_columns/1`'s output (type/max_length/nullable, no `default`).
  defp canonical_actual(expected), do: Map.take(expected, [:columns, :indexes, :primary_key])

  describe "parsing the canonical shape out of up_statements/1" do
    test "parsed_expected_columns/1 finds exactly the 11 known columns" do
      columns = Migrations.parsed_expected_columns()

      assert Enum.sort(Map.keys(columns)) ==
               Enum.sort(~w(session_id consent_type consent_given consent_version
                            ip_address user_agent_hash metadata inserted_at
                            updated_at uuid user_uuid))

      assert columns["session_id"] == %{type: "character varying", max_length: 64, nullable: true}

      assert columns["consent_type"] == %{
               type: "character varying",
               max_length: 30,
               nullable: false
             }

      assert columns["consent_given"] == %{type: "boolean", max_length: nil, nullable: false}
      assert columns["metadata"] == %{type: "jsonb", max_length: nil, nullable: true}

      assert columns["inserted_at"] == %{
               type: "timestamp with time zone",
               max_length: nil,
               nullable: false
             }

      assert columns["uuid"] == %{type: "uuid", max_length: nil, nullable: false}
      assert columns["user_uuid"] == %{type: "uuid", max_length: nil, nullable: true}
    end

    test "parsed_expected_indexes/1 finds exactly the 6 known indexes" do
      indexes = Migrations.parsed_expected_indexes()

      assert Enum.sort(Enum.map(indexes, & &1.name)) == Enum.sort(@expected_index_names)

      unique_index =
        Enum.find(indexes, &(&1.name == "phoenix_kit_consent_logs_uuid_unique_index"))

      assert unique_index.unique
      assert unique_index.columns == ["uuid"]

      composite_index =
        Enum.find(indexes, &(&1.name == "phoenix_kit_consent_logs_session_type_idx"))

      refute composite_index.unique
      assert composite_index.columns == ["session_id", "consent_type"]
    end

    test "parsed_expected_primary_key/1 finds the uuid primary key" do
      assert Migrations.parsed_expected_primary_key() == ["uuid"]
    end
  end

  describe "a canonical (core V135-shaped) table" do
    test "diffs to []" do
      expected = expected_shape()

      assert AdoptionShape.diff(expected, canonical_actual(expected)) == []
    end
  end

  describe "a narrowed column" do
    test "session_id narrowed from 64 to 32 is flagged" do
      expected = expected_shape()
      actual = put_in(canonical_actual(expected), [:columns, "session_id", :max_length], 32)

      assert [{:column_mismatch, "session_id", expected: exp, actual: act}] =
               AdoptionShape.diff(expected, actual)

      assert exp.max_length == 64
      assert act.max_length == 32
    end

    test "consent_type narrowed from 30 to 20 is flagged, independent of session_id" do
      expected = expected_shape()
      actual = put_in(canonical_actual(expected), [:columns, "consent_type", :max_length], 20)

      assert [
               {:column_mismatch, "consent_type",
                expected: %{max_length: 30}, actual: %{max_length: 20}}
             ] =
               AdoptionShape.diff(expected, actual)
    end
  end

  describe "the pre-0.3.0 varchar(255) shape (copy #2/#3 — dev_docs/reports/2026-08-10-module-migration-versioning.md)" do
    test "every widened varchar column is flagged, nothing else is" do
      expected = expected_shape()
      actual = canonical_actual(expected)

      widened_columns =
        Enum.reduce(
          ~w(session_id consent_type consent_version ip_address user_agent_hash),
          actual.columns,
          &put_in(&2, [&1, :max_length], 255)
        )

      diffs = AdoptionShape.diff(expected, %{actual | columns: widened_columns})

      flagged = for {:column_mismatch, name, _} <- diffs, do: name

      assert Enum.sort(flagged) ==
               Enum.sort(~w(session_id consent_type consent_version ip_address user_agent_hash))

      assert length(diffs) == 5
    end
  end

  describe "a nullability drift" do
    test "consent_type made nullable (NOT NULL dropped by hand) is flagged" do
      expected = expected_shape()
      actual = put_in(canonical_actual(expected), [:columns, "consent_type", :nullable], true)

      assert [
               {:column_mismatch, "consent_type",
                expected: %{nullable: false}, actual: %{nullable: true}}
             ] =
               AdoptionShape.diff(expected, actual)
    end
  end

  describe "a type drift" do
    test "consent_given changed from boolean to integer is flagged" do
      expected = expected_shape()
      actual = put_in(canonical_actual(expected), [:columns, "consent_given", :type], "integer")

      assert [{:column_mismatch, "consent_given", _}] = AdoptionShape.diff(expected, actual)
    end
  end

  describe "a missing column" do
    test "is flagged distinctly from a mismatch" do
      expected = expected_shape()

      actual =
        update_in(canonical_actual(expected), [:columns], &Map.delete(&1, "user_agent_hash"))

      assert [{:missing_column, "user_agent_hash"}] = AdoptionShape.diff(expected, actual)
    end
  end

  describe "an extra, unrelated column" do
    test "present in actual but not among the 11 known columns is never reported" do
      expected = expected_shape()

      actual =
        update_in(canonical_actual(expected), [:columns], fn columns ->
          Map.put(columns, "some_future_core_column", %{
            type: "text",
            max_length: nil,
            nullable: true
          })
        end)

      assert AdoptionShape.diff(expected, actual) == []
    end
  end

  describe "missing indexes" do
    test "every one of the six expected indexes is checked independently" do
      expected = expected_shape()

      for missing <- @expected_index_names do
        actual =
          update_in(canonical_actual(expected), [:indexes], fn indexes ->
            Enum.reject(indexes, &(&1.name == missing))
          end)

        assert [{:missing_index, ^missing}] = AdoptionShape.diff(expected, actual)
      end
    end

    test "all six missing (copy #3's Ecto-default index names) are all flagged at once" do
      expected = expected_shape()
      actual = %{canonical_actual(expected) | indexes: []}

      diffs = AdoptionShape.diff(expected, actual)

      assert Enum.sort(for {:missing_index, name} <- diffs, do: name) ==
               Enum.sort(@expected_index_names)
    end
  end

  describe "an index shape drift" do
    test "wrong uniqueness on an existing index is flagged" do
      expected = expected_shape()

      actual =
        update_in(canonical_actual(expected), [:indexes], fn indexes ->
          Enum.map(indexes, fn
            %{name: "phoenix_kit_consent_logs_uuid_unique_index"} = index ->
              %{index | unique: false}

            index ->
              index
          end)
        end)

      assert [
               {:index_mismatch, "phoenix_kit_consent_logs_uuid_unique_index",
                expected: exp, actual: act}
             ] =
               AdoptionShape.diff(expected, actual)

      assert exp.unique
      refute act.unique
    end

    test "wrong indexed columns on an existing index is flagged" do
      expected = expected_shape()

      actual =
        update_in(canonical_actual(expected), [:indexes], fn indexes ->
          Enum.map(indexes, fn
            %{name: "phoenix_kit_consent_logs_session_type_idx"} = index ->
              %{index | columns: ["session_id"]}

            index ->
              index
          end)
        end)

      assert [
               {:index_mismatch, "phoenix_kit_consent_logs_session_type_idx",
                expected: exp, actual: act}
             ] =
               AdoptionShape.diff(expected, actual)

      assert exp.columns == ["session_id", "consent_type"]
      assert act.columns == ["session_id"]
    end
  end

  describe "the primary key" do
    test "missing entirely is flagged" do
      expected = expected_shape()
      actual = %{canonical_actual(expected) | primary_key: []}

      assert [{:primary_key_mismatch, expected: ["uuid"], actual: []}] =
               AdoptionShape.diff(expected, actual)
    end

    test "on the wrong column is flagged" do
      expected = expected_shape()
      actual = %{canonical_actual(expected) | primary_key: ["id"]}

      assert [{:primary_key_mismatch, expected: ["uuid"], actual: ["id"]}] =
               AdoptionShape.diff(expected, actual)
    end
  end

  describe "several drifts at once" do
    test "every one is reported, not just the first" do
      expected = expected_shape()

      actual =
        canonical_actual(expected)
        |> put_in([:columns, "session_id", :max_length], 255)
        |> update_in([:columns], &Map.delete(&1, "ip_address"))
        |> update_in(
          [:indexes],
          &Enum.reject(&1, fn idx -> idx.name == "phoenix_kit_consent_logs_type_idx" end)
        )
        |> Map.put(:primary_key, [])

      diffs = AdoptionShape.diff(expected, actual)

      assert length(diffs) == 4

      assert {:column_mismatch, "session_id", _} =
               Enum.find(diffs, &match?({:column_mismatch, "session_id", _}, &1))

      assert {:missing_column, "ip_address"} in diffs
      assert {:missing_index, "phoenix_kit_consent_logs_type_idx"} in diffs
      assert {:primary_key_mismatch, expected: ["uuid"], actual: []} in diffs
    end
  end

  describe "format/1" do
    @diffs [
      {:column_mismatch, "session_id",
       expected: %{type: "character varying", max_length: 64, nullable: true},
       actual: %{type: "character varying", max_length: 255, nullable: true}},
      {:missing_index, "phoenix_kit_consent_logs_type_idx"},
      {:index_mismatch, "phoenix_kit_consent_logs_uuid_unique_index",
       expected: %{unique: true, columns: ["uuid"]}, actual: %{unique: false, columns: ["uuid"]}},
      {:primary_key_mismatch, expected: ["uuid"], actual: []}
    ]

    test "names every drifted field" do
      message = AdoptionShape.format(@diffs)

      assert message =~ "session_id"
      assert message =~ "character varying(64)"
      assert message =~ "character varying(255)"
      assert message =~ "phoenix_kit_consent_logs_type_idx"
      assert message =~ "phoenix_kit_consent_logs_uuid_unique_index"
      assert message =~ "primary key"
    end

    test "states that no existing column's type or width is ever changed automatically" do
      message = AdoptionShape.format(@diffs)

      assert message =~ "No existing column's type or width is ever changed automatically"
    end

    test "warns that :warn is not risk-free — it can itself fail with a raw Postgres error" do
      message = AdoptionShape.format(@diffs)

      assert message =~ "not risk-free"
      assert message =~ "42P16 multiple primary keys"
      assert message =~ "42703 column"
      assert message =~ ~s(SOME shapes of this table's drift still do)
    end

    test "says ALTER fails outright on over-length data — never that it silently truncates" do
      message = AdoptionShape.format(@diffs)

      assert message =~
               "ALTER TABLE ... ALTER COLUMN ... TYPE character varying(N) fails outright"

      assert message =~ "value too long for type character varying(N)"
      refute message =~ "truncat"
    end

    test "gives a concrete, runnable reconciliation procedure" do
      message = AdoptionShape.format(@diffs)

      assert message =~ "SELECT count(*) FROM phoenix_kit_consent_logs WHERE length("
    end

    test "mentions mix phoenix_kit.doctor as a second opinion, not a fix" do
      message = AdoptionShape.format(@diffs)

      assert message =~ "mix phoenix_kit.doctor"
      assert message =~ "not a fix"
    end

    test "explains both modes: :raise leaves nothing written and retries via the reused migration file, :warn writes the marker and does not retry" do
      message = AdoptionShape.format(@diffs)

      assert message =~ "config :phoenix_kit_legal, :adoption_shape_check, :warn"
      assert message =~ "the pkl_schema:1 marker is NOT written"
      assert message =~ "does not record this migration as applied"
      assert message =~ "reusing the migration file already generated, not writing a new one"
      assert message =~ "the marker gets written despite the drift"
      assert message =~ "will NOT run again automatically"
    end

    test "does not point at AGENTS.md or claim mix phoenix_kit.repair fixes this" do
      message = AdoptionShape.format(@diffs)

      refute message =~ "AGENTS.md"
      refute message =~ "mix phoenix_kit.repair"
    end
  end

  describe "adoption_shape_check_mode/0" do
    setup do
      previous = Application.fetch_env(:phoenix_kit_legal, :adoption_shape_check)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit_legal, :adoption_shape_check, value)
          :error -> Application.delete_env(:phoenix_kit_legal, :adoption_shape_check)
        end
      end)

      :ok
    end

    test "defaults to :raise when unset" do
      Application.delete_env(:phoenix_kit_legal, :adoption_shape_check)
      assert Migrations.adoption_shape_check_mode() == :raise
    end

    test "accepts :raise and :warn" do
      Application.put_env(:phoenix_kit_legal, :adoption_shape_check, :raise)
      assert Migrations.adoption_shape_check_mode() == :raise

      Application.put_env(:phoenix_kit_legal, :adoption_shape_check, :warn)
      assert Migrations.adoption_shape_check_mode() == :warn
    end

    test "raises a clear ArgumentError, not an opaque CaseClauseError, for anything else" do
      Application.put_env(:phoenix_kit_legal, :adoption_shape_check, :warning)

      assert_raise ArgumentError, ~r/:raise or :warn, got: :warning/, fn ->
        Migrations.adoption_shape_check_mode()
      end
    end
  end
end
