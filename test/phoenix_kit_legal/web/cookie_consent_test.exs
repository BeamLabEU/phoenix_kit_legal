defmodule PhoenixKit.Modules.Legal.CookieConsentTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.CookieConsent
  alias PhoenixKit.Users.Auth.Scope

  @hide_key "legal_hide_for_authenticated"

  setup do
    # Default each test to hide_for_authenticated?=true (same as prod default).
    PhoenixKit.Cache.put(:settings, @hide_key, "true")
    :ok
  end

  defp authenticated_scope do
    %Scope{authenticated?: true, user: %{id: 1}}
  end

  defp anonymous_scope do
    %Scope{authenticated?: false, user: nil}
  end

  defp render(opts) do
    render_component(
      &CookieConsent.cookie_consent/1,
      Keyword.merge([frameworks: ["gdpr"], consent_mode: "strict"], opts)
    )
  end

  test "renders full widget when scope is nil (backward-compatible)" do
    html = render(phoenix_kit_current_scope: nil)
    assert html =~ "pk-consent-root"
    assert html =~ "pk-consent-banner"
  end

  test "renders full widget for anonymous scope" do
    html = render(phoenix_kit_current_scope: anonymous_scope())
    assert html =~ "pk-consent-root"
  end

  test "returns empty output for authenticated scope when hide_for_authenticated? is true" do
    PhoenixKit.Cache.put(:settings, @hide_key, "true")
    html = render(phoenix_kit_current_scope: authenticated_scope())
    refute html =~ "pk-consent-root"
    assert String.trim(html) == ""
  end

  test "renders full widget for authenticated scope when hide_for_authenticated? is false" do
    PhoenixKit.Cache.put(:settings, @hide_key, "false")
    html = render(phoenix_kit_current_scope: authenticated_scope())
    assert html =~ "pk-consent-root"
  end

  test "renders full widget when scope is a plain map (non-Scope struct, no crash)" do
    html = render(phoenix_kit_current_scope: %{authenticated?: true, user: %{id: 1}})
    assert html =~ "pk-consent-root"
  end

  describe "what the banner script needs to report a decision" do
    setup do
      PhoenixKit.Cache.put(:settings, "legal_consent_cookie_days", "90")
      PhoenixKit.Cache.put(:settings, "legal_consent_reload_on_withdrawal", "false")
      PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => []})
      :ok
    end

    test "is on the root element" do
      html = render(phoenix_kit_current_scope: nil)

      assert html =~ ~s(data-consent-endpoint="/phoenix_kit/api/consent")
      assert html =~ ~s(data-cookie-name="pk_consent")
      assert html =~ ~s(data-cookie-days="90")
      assert html =~ ~s(data-reload-on-withdrawal="false")
    end

    test "a category with nothing declared under it says nothing about what it covers" do
      # No module registry runs in this suite, so nothing is declared.
      refute render(phoenix_kit_current_scope: nil) =~ "data-covers"
    end

    test "a category says what it covers when something is declared under it" do
      html =
        render(
          phoenix_kit_current_scope: nil,
          purposes: %{
            "necessary" => ["Your privacy choices"],
            "analytics" => ["Page statistics", "Search <terms>"],
            "marketing" => []
          }
        )

      assert [necessary, analytics] =
               Regex.scan(~r/<p[^>]*data-covers="(\w+)"[^>]*>(.*?)<\/p>/s, html,
                 capture: :all_but_first
               )

      assert ["necessary", text] = necessary
      assert text =~ "Covers:"
      assert text =~ "Your privacy choices"

      assert ["analytics", text] = analytics
      assert text =~ "Page statistics, Search &lt;terms&gt;"

      # Nothing under an empty category, nor under one left out.
      refute html =~ ~s(data-covers="marketing")
      refute html =~ ~s(data-covers="preferences")
    end

    test "the script's part of the widget config is complete and is JSON" do
      config = Legal.consent_record_config()

      assert %{
               consent_endpoint: "/phoenix_kit/api/consent",
               cookie_name: "pk_consent",
               cookie_days: 90,
               reload_on_withdrawal: false,
               purposes: purposes
             } = config

      assert is_map(purposes)

      # Core's consent-config controller sends the whole map as JSON.
      assert config |> Jason.encode!() |> Jason.decode!() == %{
               "consent_endpoint" => "/phoenix_kit/api/consent",
               "cookie_name" => "pk_consent",
               "cookie_days" => 90,
               "reload_on_withdrawal" => false,
               "purposes" => Map.new(purposes, fn {category, titles} -> {category, titles} end)
             }
    end
  end

  test "renders full widget for unknown struct (scope ignored, no crash)" do
    html = render(phoenix_kit_current_scope: %URI{host: "example.com"})
    assert html =~ "pk-consent-root"
  end
end
