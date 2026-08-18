defmodule PhoenixKitLegal.SchemaPrefixConformanceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal.ConsentLog

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support: every
  table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries
  target the schema core's migrations installed into. A schema missing
  it silently falls back to `search_path` resolution — invisible on
  public installs, broken on prefixed ones.

  The conformance assertion is `offenders == []`, and on its own that is a
  check that cannot fail: it is satisfied by finding no schemas at all. Both
  ways of finding none were reproduced — a file glob that matches nothing, and
  a marker that no longer matches the `schema` call — and each left the test
  green while telling nobody. So the discovery is asserted before the
  conformance is: the glob must see this package's `lib/`, and the set of
  table-backed schemas it finds must contain the one this module is known to
  own. Only then is `offenders == []` worth anything.
  """

  # Tolerant of both call forms. `schema "x"` and `schema("x")` are the same
  # code; a marker that only matches the first turns an idiomatic rewrite into
  # a silently unchecked schema.
  @table_backed ~r/schema\s*\(?\s*"phoenix_kit/
  @conformance "use PhoenixKit.SchemaPrefix"

  test "the discovery this conformance check depends on is live" do
    files = lib_files()

    assert files != [],
           "no files matched lib/**/*.ex — the glob is not seeing this package's " <>
             "source tree, and every conformance assertion built on it is vacuous"

    table_backed = table_backed_files(files)

    assert table_backed != [],
           "no table-backed schema was found in lib/**/*.ex, though this module " <>
             "owns #{ConsentLog.__schema__(:source)}. The marker #{inspect(@table_backed.source)} " <>
             "has stopped matching how the schema is declared."

    # Anchored to the schema module rather than a path literal: the file must be
    # the one that defines the source table `ConsentLog` reports.
    assert Enum.any?(table_backed, &(File.read!(&1) =~ ConsentLog.__schema__(:source))),
           "the table-backed set #{inspect(table_backed)} does not include the file " <>
             "declaring #{ConsentLog.__schema__(:source)} — discovery is partial, so " <>
             "the conformance check below covers less than it appears to"
  end

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      lib_files()
      |> table_backed_files()
      |> Enum.reject(&String.contains?(File.read!(&1), @conformance))

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")

  defp table_backed_files(files),
    do: Enum.filter(files, &(File.read!(&1) =~ @table_backed))
end
