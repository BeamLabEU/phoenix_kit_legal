defmodule PhoenixKit.Modules.Legal.Web.SettingsTemplateTest do
  @moduledoc """
  The settings page's buttons, read as source: rendering the page needs
  Publishing and a database, and what is checked here is in the markup.
  """

  use ExUnit.Case, async: true

  @template Path.expand("../../../lib/phoenix_kit_legal/web/settings.html.heex", __DIR__)

  # Every opening tag of `name`, attributes and all. None of these tags holds
  # a `>` inside an attribute.
  defp tags(source, name), do: Regex.scan(~r/<#{name}\b[^>]*>/s, source) |> List.flatten()

  defp event(tag) do
    case Regex.run(~r/phx-click="(\w+)"/, tag) do
      [_, event] -> event
      nil -> nil
    end
  end

  setup_all do
    %{source: File.read!(@template), buttons: tags(File.read!(@template), "button")}
  end

  test "a button that starts slow or irreversible work disables itself with a label", %{
    buttons: buttons
  } do
    expected = %{
      "generate_page" => "Generating...",
      "generate_all_pages" => "Generating...",
      "publish_page" => "Publishing...",
      "reset_legal_pages" => "Resetting...",
      "import_dpo_email" => "Importing...",
      "import_dpo_address" => "Importing..."
    }

    by_event = buttons |> Enum.filter(&event/1) |> Enum.group_by(&event/1)

    # Each of them is on the page: a renamed event would otherwise pass by
    # finding nothing to check.
    assert Enum.sort(Map.keys(by_event)) == Enum.sort(Map.keys(expected))

    for {event, label} <- expected, button <- by_event[event] do
      assert button =~ ~s[phx-disable-with={gettext("#{label}")}], "#{event}: #{button}"
    end
  end

  test "every form's submit button does too", %{source: source, buttons: buttons} do
    forms = source |> tags("form") |> Enum.filter(&(&1 =~ "phx-submit"))
    submits = Enum.filter(buttons, &(&1 =~ ~s(type="submit")))

    assert length(forms) == 2
    assert length(submits) == length(forms)

    for button <- submits do
      assert button =~ ~s[phx-disable-with={gettext("Saving...")}], button
    end
  end

  test "the preview's mock buttons and the plain toggles are left alone", %{
    source: source,
    buttons: buttons
  } do
    plain = Enum.reject(buttons, &(event(&1) || &1 =~ ~s(type="submit")))

    # The three buttons of the banner preview.
    assert length(plain) == 3
    refute Enum.any?(plain, &(&1 =~ "phx-disable-with"))

    toggles = source |> tags("input") |> Enum.filter(&event/1)
    assert length(toggles) >= 3
    refute Enum.any?(toggles, &(&1 =~ "phx-disable-with"))
  end

  test "the days field has one label a translator can read whole", %{source: source} do
    assert source =~ ~s[{gettext("Ask again after (days)")}]
    # Two halves around an input cannot be reordered in a language that
    # puts the number first.
    refute source =~ ~s[gettext("Ask again after")]
    refute source =~ ~s[gettext("days")]
  end
end
