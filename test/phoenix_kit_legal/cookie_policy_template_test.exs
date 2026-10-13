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

    assert render([necessary]) =~ "| pk_consent (cookie) | Your choices | 180 days |"
  end
end
