defmodule PhoenixKit.Modules.Legal.CssSourcesTest do
  @moduledoc """
  Pins that `css_sources/0` emits the absolute source root only when the
  `:phoenix_kit_legal` atom entry does not already cover it.

  Regression guard. Through 0.1.10 the callback returned
  `[:phoenix_kit_legal, @source_root]` unconditionally, and the compiler's
  `Enum.uniq/1` runs on the raw entries — an atom and a string, never equal —
  before formatting, so a plain Hex install got the same directory twice in
  `assets/css/_phoenix_kit_sources.css`, the second time under a build-machine
  absolute path.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal

  describe "css_sources/2" do
    test "omits the absolute root on a standard deps/ install" do
      assert Legal.css_sources("/www/app/deps/phoenix_kit_legal", "/www/app") ==
               [:phoenix_kit_legal]
    end

    test "keeps the absolute root for a path dep outside deps/" do
      assert Legal.css_sources("/workspace/phoenix_kit_legal", "/workspace/host") ==
               [:phoenix_kit_legal, "/workspace/phoenix_kit_legal"]
    end

    test "keeps the absolute root when deps/ is not under the project root" do
      assert Legal.css_sources("/umbrella/deps/phoenix_kit_legal", "/umbrella/apps/my_app") ==
               [:phoenix_kit_legal, "/umbrella/deps/phoenix_kit_legal"]
    end
  end

  describe "css_sources/0" do
    test "always lists the OTP app, and never the same directory twice" do
      sources = Legal.css_sources()

      assert :phoenix_kit_legal in sources
      assert sources == Enum.uniq(sources)

      # Whatever the layout, the atom and any absolute entry must not resolve to
      # the same directory — that pair is exactly what produced duplicate
      # @source lines in the generated CSS.
      atom_target = Path.expand("deps/phoenix_kit_legal", File.cwd!())
      refute atom_target in sources
    end
  end
end
