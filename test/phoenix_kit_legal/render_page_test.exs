defmodule PhoenixKit.Modules.Legal.RenderPageTest do
  @moduledoc """
  `render_page/2` and `policy_record/1`. A render reads company/DPO info
  through `Settings.get_json_setting/2`, which always queries the
  database, so each test runs against a session-local `phoenix_kit_settings`
  shadow (`CREATE TEMP TABLE` inside a rolled-back transaction), as
  `consent_log_write_test.exs` does for the consent log.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Test.Repo

  @moduletag :integration

  setup do
    previous = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, Repo)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :repo, previous),
        else: Application.delete_env(:phoenix_kit, :repo)
    end)

    PhoenixKit.Cache.put(:settings, "legal_frameworks", %{"items" => ["gdpr"]})
    PhoenixKit.Cache.put(:settings, "legal_page_templates", %{})
    PhoenixKit.Cache.put(:settings, "legal_hidden_collection", ~s({"items": []}))
    :ok
  end

  defp with_settings(fun) do
    Repo.transaction(fn ->
      Repo.query!("""
      CREATE TEMP TABLE phoenix_kit_settings (
        uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        key varchar(255) NOT NULL,
        value text,
        value_json jsonb,
        module varchar(255),
        date_added timestamp(0) NOT NULL DEFAULT now(),
        date_updated timestamp(0) NOT NULL DEFAULT now()
      ) ON COMMIT DROP
      """)

      # Empty: every setting reads as its default (an unconfigured site).
      fun.()
      Repo.rollback(:done)
    end)
  end

  test "renders a page in Estonian with its locale and template version" do
    with_settings(fn ->
      assert {:ok, page} = Legal.render_page("privacy-policy", language: "et")
      assert page.slug == "privacy-policy"
      assert page.language == "et"
      assert page.locale == "et"
      assert page.template_version =~ ~r/^sha256:/
      assert String.starts_with?(page.content, "# ")
    end)
  end

  test "falls back to English and says so" do
    with_settings(fn ->
      assert {:ok, page} = Legal.render_page("privacy-policy", language: "de")
      assert page.language == "de"
      assert page.locale == "en"
      assert page.content =~ "# Privacy Policy"
    end)
  end

  test "an unknown page type is an error" do
    assert {:error, :unknown_page_type} = Legal.render_page("nope")
  end

  test "policy_record/1 names the language, the policy language and each page's template" do
    record = Legal.policy_record("ru")
    assert record["locale"] == "ru"
    assert record["policy_locale"] == "ru"

    assert %{"privacy-policy" => "sha256:" <> _, "cookie-policy" => "sha256:" <> _} =
             record["template_versions"]

    assert Legal.policy_record("<script>")["locale"] == nil
    assert Legal.policy_record(nil)["policy_locale"] == "en"
  end

  test "policy_record/1 prefers the template a generated page was written from" do
    PhoenixKit.Cache.put(:settings, "legal_page_templates", %{
      "privacy-policy" => %{
        "et" => %{"locale" => "et", "template_version" => "sha256:recorded0000"}
      }
    })

    assert Legal.policy_record("et")["template_versions"]["privacy-policy"] ==
             "sha256:recorded0000"
  end

  test "policy_record/1 finds the page generated in the base language for a regional code" do
    PhoenixKit.Cache.put(:settings, "legal_page_templates", %{
      "privacy-policy" => %{
        "et" => %{"locale" => "et", "template_version" => "sha256:recorded0000"}
      }
    })

    assert Legal.policy_record("et-EE")["template_versions"]["privacy-policy"] ==
             "sha256:recorded0000"
  end

  test "policy_record/1 takes the policy language from the generated page's record" do
    # A page generated for "et" from a host's English-only override.
    PhoenixKit.Cache.put(:settings, "legal_page_templates", %{
      "privacy-policy" => %{
        "et" => %{"locale" => "en", "template_version" => "sha256:recorded0000"}
      }
    })

    record = Legal.policy_record("et")
    assert record["policy_locale"] == "en"
  end

  test "policy_record/1 survives a malformed recorded entry" do
    PhoenixKit.Cache.put(:settings, "legal_page_templates", %{"privacy-policy" => "x"})
    record = Legal.policy_record("et")
    assert record["policy_locale"] == "et"
    assert %{"privacy-policy" => "sha256:" <> _} = record["template_versions"]
  end

  test "render_page/2 with a nil language renders English" do
    with_settings(fn ->
      assert {:ok, page} = Legal.render_page("privacy-policy", language: nil)
      assert page.locale == "en"
    end)
  end

  test "clean_locale/1 keeps language codes only" do
    assert Legal.clean_locale("et") == "et"
    assert Legal.clean_locale(" zh_Hant ") == "zh_Hant"
    assert Legal.clean_locale("e") == nil
    assert Legal.clean_locale(String.duplicate("a", 40)) == nil
    assert Legal.clean_locale(42) == nil
  end
end
