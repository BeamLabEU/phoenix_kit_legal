defmodule PhoenixKit.Modules.Legal.CookiePolicyTemplateTest do
  @moduledoc """
  The bundled Cookie Policy is written from what the site's modules declare,
  not from a list of somebody else's cookies.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal.DataCollection
  alias PhoenixKit.Modules.Legal.TemplateGenerator

  @context %{
    company_name: "Acme",
    company_address: "",
    company_country: "",
    company_website: "",
    registration_number: "",
    vat_number: "",
    dpo_name: "",
    dpo_email: "",
    dpo_phone: "",
    dpo_address: "",
    frameworks: ["gdpr"],
    effective_date: "2026-10-13"
  }

  defp entry(attrs) do
    Map.merge(
      %{
        key: "x",
        module: "x",
        title: "Visit statistics",
        description: "Counts visits.",
        category: "analytics",
        mode: :consent,
        active: true,
        data: ["Pages viewed"],
        retention: "365 days",
        storage: [],
        basis: "Your consent"
      },
      attrs
    )
  end

  defp render(entries) do
    context = Map.put(@context, :data_collection, DataCollection.by_category(entries))
    assert {:ok, content} = TemplateGenerator.render("cookie_policy.eex", context)
    content
  end

  test "names no third-party cookie nobody declared" do
    content = render([])

    for name <- ~w(_ga _gid _gat _fbp _gcl_au), do: refute(content =~ name)
    assert content =~ "We do not currently use cookies or similar technologies in this category."
  end

  test "lists what a module declares, with its legal ground and how long it is kept" do
    content = render([entry(%{})])

    assert content =~ "#### Visit statistics"
    assert content =~ "Counts visits."
    assert content =~ "- Pages viewed"
    assert content =~ "**Legal basis:** Your consent"
    assert content =~ "**Kept for:** 365 days"
  end

  test "says so when a category collects without storing anything on the device" do
    content = render([entry(%{})])
    assert content =~ "Nothing in this category is stored on your device."
  end

  test "puts declared storage in its category's table" do
    stored =
      entry(%{
        category: "marketing",
        storage: [%{name: "ad_id", kind: "cookie", duration: "90 days", purpose: "Ad reach"}]
      })

    assert render([stored]) =~ "| ad_id | cookie | Ad reach | 90 days |"
  end

  test "adds a necessary module's storage to the necessary table" do
    necessary =
      entry(%{
        category: "necessary",
        storage: [
          %{name: "pk_consent", kind: "cookie", duration: "180 days", purpose: "Your choices"}
        ]
      })

    content = render([necessary])
    assert content =~ "| pk_consent (cookie) | Your choices | 180 days |"

    # After the rows that describe the host's own cookies, in the same table.
    assert content =~
             "| Sign-in reminder cookie | Keeps you signed in when you ask to be remembered | Set by the site |\n" <>
               "| pk_consent (cookie) | Your choices | 180 days |"
  end

  test "describes the host's own cookies without inventing their names" do
    content = render([])

    # The names are the host's: a session cookie is `_myapp_key`, not `session_id`.
    for name <- ~w(session_id csrf_token remember_token), do: refute(content =~ name)

    assert content =~
             "| Site session cookie | Keeps you signed in and protects forms against forgery | Session |"

    assert content =~ "| Sign-in reminder cookie |"
  end

  test "lists what is collected in the order of the sections above it" do
    # Given in another order, and a map has its own (alphabetical) one.
    entries =
      for {category, title} <- [
            {"marketing", "Fourth: adverts"},
            {"analytics", "Second: statistics"},
            {"preferences", "Third: settings"},
            {"necessary", "First: sign-in"}
          ],
          do: entry(%{category: category, title: title, key: category})

    content = render(entries)

    positions =
      for title <- ["First: sign-in", "Second: statistics", "Third: settings", "Fourth: adverts"] do
        {position, _length} = :binary.match(content, "#### " <> title)
        position
      end

    assert positions == Enum.sort(positions)
  end

  test "a context without the declarations still renders, declaring nothing" do
    assert {:ok, content} = TemplateGenerator.render("cookie_policy.eex", @context)
    assert content =~ "We do not currently use cookies or similar technologies in this category."

    # String keys are a context too.
    string_keyed = Map.new(@context, fn {key, value} -> {Atom.to_string(key), value} end)
    assert {:ok, ^content} = TemplateGenerator.render("cookie_policy.eex", string_keyed)

    # And every other bundled template renders from the same bare context.
    for template <- TemplateGenerator.list_available_templates() do
      assert {:ok, _} = TemplateGenerator.render(template, @context), template
    end
  end
end

defmodule PhoenixKit.Modules.Legal.TemplateCollectionTest do
  @moduledoc """
  The data the Cookie Policy is written from: `Legal.template_collection/2`.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.TemplateGenerator

  defmodule Awkward do
    def module_key, do: "awkward"

    def data_collection do
      [
        %{
          key: "awkward.entry",
          title: "Search | filters",
          description: "First line.\nSecond line.",
          category: "marketing",
          mode: :consent,
          data: ["Query | page", "Two\r\nlines"],
          retention: "30 days | then deleted",
          storage: [
            %{
              name: "q|id",
              kind: "cookie",
              duration: "1 | 2 days",
              purpose: "Keeps\n the | query"
            }
          ]
        },
        %{key: "awkward.off", title: "Switched off", category: "analytics", mode: :off}
      ]
    end
  end

  defmodule Slow do
    def module_key, do: "slow"

    def data_collection do
      Process.sleep(:infinity)
      []
    end
  end

  @context %{
    company_name: "Acme",
    company_address: "",
    company_website: "",
    dpo_email: "",
    frameworks: [],
    effective_date: "2026-10-13"
  }

  setup do
    PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => []})
    :ok
  end

  test "declared text cannot break a table row or a heading" do
    assert {:ok, collection} = Legal.template_collection("en", modules: [Awkward])
    assert [entry] = collection["marketing"]

    assert entry.title == "Search \\| filters"
    assert entry.description == "First line. Second line."
    assert entry.data == ["Query \\| page", "Two lines"]
    assert entry.retention == "30 days \\| then deleted"
    assert entry.basis == "Your consent"

    assert entry.storage == [
             %{
               name: "q\\|id",
               kind: "cookie",
               duration: "1 \\| 2 days",
               purpose: "Keeps the \\| query"
             }
           ]

    {:ok, content} =
      TemplateGenerator.render(
        "cookie_policy.eex",
        Map.put(@context, :data_collection, collection)
      )

    # One row, four cells: every `|` that is not a cell border is escaped.
    row = content |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| q"))
    assert row == "| q\\|id | cookie | Keeps the \\| query | 1 \\| 2 days |"
    assert row |> String.replace("\\|", "") |> String.graphemes() |> Enum.count(&(&1 == "|")) == 5

    assert content =~ "#### Search \\| filters\n"
    assert content =~ "- Two lines\n"
  end

  test "what is switched off is not in the policy" do
    assert {:ok, collection} = Legal.template_collection("en", modules: [Awkward])
    assert collection["analytics"] == []
  end

  test "every category is there, so a template can read any of them" do
    assert {:ok, collection} = Legal.template_collection("en", modules: [])

    assert collection == %{
             "necessary" => [],
             "analytics" => [],
             "marketing" => [],
             "preferences" => []
           }
  end

  test "a list that cannot be gathered is an error, never an empty policy" do
    assert Legal.template_collection("en", modules: [Slow], timeout: 20) ==
             {:error, {:data_collection, :timeout}}
  end
end
