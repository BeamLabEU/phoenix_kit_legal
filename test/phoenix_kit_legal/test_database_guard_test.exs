defmodule PhoenixKit.Modules.Legal.Test.DatabaseGuardTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal.Test.DatabaseGuard

  describe "safe?/1" do
    test "accepts this package's own database, unpartitioned" do
      assert DatabaseGuard.safe?("phoenix_kit_legal_test")
    end

    test "accepts this package's own database with a numeric MIX_TEST_PARTITION suffix" do
      assert DatabaseGuard.safe?("phoenix_kit_legal_test1")
      assert DatabaseGuard.safe?("phoenix_kit_legal_test42")
    end

    test "rejects core's own shared test fixture" do
      refute DatabaseGuard.safe?("phoenix_kit_test")
    end

    test "rejects another package's test database" do
      refute DatabaseGuard.safe?("phoenix_kit_billing_test")
      refute DatabaseGuard.safe?("phoenix_kit_dashboards_test")
    end

    test "rejects a development database" do
      refute DatabaseGuard.safe?("phoenix_kit_dev")
      refute DatabaseGuard.safe?("phoenix_kit_legal_dev")
    end

    test "rejects an arbitrary name" do
      refute DatabaseGuard.safe?("some_random_name")
    end

    test "rejects a partition suffix that isn't purely numeric" do
      refute DatabaseGuard.safe?("phoenix_kit_legal_test_extra")
      refute DatabaseGuard.safe?("phoenix_kit_legal_testing")
    end
  end

  describe "validate!/1" do
    test "returns :ok for a safe name" do
      assert :ok = DatabaseGuard.validate!("phoenix_kit_legal_test")
    end

    test "raises for an unsafe name, naming it in the message" do
      assert_raise RuntimeError,
                   ~r/phoenix_kit_test.*does not look like this package's own/s,
                   fn ->
                     DatabaseGuard.validate!("phoenix_kit_test")
                   end
    end
  end

  describe "test_helper.exs calls validate!/1 before probing the connection" do
    # The mutation this catches: deleting the call to DatabaseGuard from
    # test_helper.exs. Every test above proves the PREDICATE is correct;
    # none of them proves anything actually calls it before a real
    # connection is attempted — this does.
    test "the source references DatabaseGuard.validate!" do
      source = File.read!("test/test_helper.exs")

      assert source =~ "DatabaseGuard.validate!",
             "test_helper.exs no longer calls DatabaseGuard.validate!/1 — the " <>
               "database-name safety check is dead code if nothing invokes it " <>
               "before the connection probe"
    end
  end
end
