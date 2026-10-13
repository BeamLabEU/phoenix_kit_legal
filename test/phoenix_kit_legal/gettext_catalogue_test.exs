defmodule PhoenixKit.Modules.Legal.GettextCatalogueTest do
  @moduledoc """
  Every string this package shows is translated into every language it ships.

  A missing or fuzzy entry does not fail anything at runtime: Gettext falls
  back to the English msgid, so the gap only shows as one English sentence
  in the middle of a German page.
  """

  use ExUnit.Case, async: true

  alias Expo.Message

  @gettext_dir Path.expand("../../priv/gettext", __DIR__)
  @translated ~w(de et fr ru)

  defp messages(path) do
    path |> Expo.PO.parse_file!() |> Map.fetch!(:messages) |> Enum.reject(& &1.obsolete)
  end

  defp id(%Message.Singular{msgid: msgid}), do: IO.iodata_to_binary(msgid)
  defp id(%Message.Plural{msgid: msgid}), do: IO.iodata_to_binary(msgid)

  defp translations(%Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp translations(%Message.Plural{msgstr: msgstr}),
    do: msgstr |> Map.values() |> Enum.map(&IO.iodata_to_binary/1)

  defp fuzzy?(message), do: Message.has_flag?(message, "fuzzy")

  setup_all do
    template = @gettext_dir |> Path.join("default.pot") |> messages() |> Enum.map(&id/1)

    # A template that did not parse into anything would make every check
    # below pass while checking nothing.
    assert length(template) > 100
    %{template: template}
  end

  for language <- @translated do
    test "#{language} has a translation for every string", %{template: template} do
      catalogue =
        @gettext_dir
        |> Path.join("#{unquote(language)}/LC_MESSAGES/default.po")
        |> messages()
        |> Map.new(&{id(&1), &1})

      missing = Enum.reject(template, &Map.has_key?(catalogue, &1))
      assert missing == [], "not in the #{unquote(language)} catalogue"

      untranslated =
        for msgid <- template,
            message = catalogue[msgid],
            translations = translations(message),
            translations == [] or Enum.any?(translations, &(String.trim(&1) == "")),
            do: msgid

      assert untranslated == [], "untranslated in #{unquote(language)}"

      fuzzy = for msgid <- template, fuzzy?(catalogue[msgid]), do: msgid
      assert fuzzy == [], "fuzzy in #{unquote(language)}"
    end
  end

  test "en is left empty on purpose: the msgid is the English text", %{template: template} do
    catalogue =
      @gettext_dir
      |> Path.join("en/LC_MESSAGES/default.po")
      |> messages()
      |> Map.new(&{id(&1), &1})

    assert Enum.reject(template, &Map.has_key?(catalogue, &1)) == []
    refute Enum.any?(Map.values(catalogue), &fuzzy?/1)
  end
end
