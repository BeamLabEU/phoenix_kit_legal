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

  defmodule TranslationStore do
    alias PhoenixKit.Modules.Legal.PageStore
    @behaviour PageStore

    for {name, arity} <- PageStore.behaviour_info(:callbacks),
        {name, arity} not in [fetch_group: 1, read_post: 2, read_post: 4, update_post: 4] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: PageStore.None
    end

    def fetch_group(_), do: {:ok, %{}}
    def read_post(_, _), do: {:ok, %{uuid: "existing", available_languages: ["en", "et", "ru"]}}
    def read_post(_, _, "et", _), do: {:error, :store_unavailable}
    def read_post(_, _, "ru", _), do: {:ok, %{language: "en"}}
    def read_post(_, _, "en", _), do: {:ok, %{language: "en"}}

    def update_post(_, %{language: "en"}, %{"content" => "# Privacy Policy" <> _}, _),
      do: {:ok, %{language: "en"}}

    def update_post(_, _, _, _), do: raise("A failed translation lookup reached the writer")
  end

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
    assert {:error, :done} =
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

  test "a failed or fallback translation lookup leaves the primary page intact" do
    Application.put_env(:phoenix_kit_legal, :page_store, TranslationStore)
    on_exit(fn -> Application.delete_env(:phoenix_kit_legal, :page_store) end)

    with_settings(fn ->
      assert {:error, :store_unavailable} = Legal.generate_page("privacy-policy", language: "et")

      assert {:error, :translation_unavailable} =
               Legal.generate_page("privacy-policy", language: "ru")
    end)
  end

  test "a successful store write records the rendered template" do
    Application.put_env(:phoenix_kit_legal, :page_store, TranslationStore)
    on_exit(fn -> Application.delete_env(:phoenix_kit_legal, :page_store) end)

    with_settings(fn ->
      Repo.query!("""
      CREATE TEMP TABLE phoenix_kit_activities (
        uuid uuid PRIMARY KEY, action varchar(255), module varchar(255), mode varchar(255),
        actor_uuid uuid, resource_type varchar(255), resource_uuid uuid, target_uuid uuid,
        metadata jsonb, permanent boolean, inserted_at timestamp
      ) ON COMMIT DROP
      """)

      assert {:ok, rendered} = Legal.render_page("privacy-policy")
      assert {:ok, _post} = Legal.generate_page("privacy-policy", language: "en")

      assert Legal.generated_page_templates()["privacy-policy"]["en"]["template_version"] ==
               rendered.template_version
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

    assert record["template_sources"]["privacy-policy"] == "resolved"

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

  test "recorded regional tags match across spelling and case" do
    PhoenixKit.Cache.put(:settings, "legal_page_templates", %{
      "privacy-policy" => %{"et-EE" => %{"locale" => "et", "template_version" => "regional"}}
    })

    record = Legal.policy_record("ET_ee")
    assert record["template_versions"]["privacy-policy"] == "regional"
    assert record["template_sources"]["privacy-policy"] == "generated"
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

  test "a generated page's title is in the language of its body" do
    with_settings(fn ->
      assert {:ok, de} = Legal.render_page("privacy-policy", language: "de")
      assert {:ok, en} = Legal.render_page("privacy-policy", language: "en")
      assert {:ok, et} = Legal.render_page("privacy-policy", language: "et")
      assert de.title == en.title
      refute et.title == en.title
    end)
  end

  describe "the page actually served" do
    setup do
      on_exit(fn -> Application.delete_env(:phoenix_kit_legal, :page_store) end)

      PhoenixKit.Cache.put(:settings, "legal_page_templates", %{
        "privacy-policy" => %{
          "_primary" => "en",
          "en" => %{"locale" => "en", "template_version" => "sha256:primary0000"}
        }
      })

      :ok
    end

    # The store has no Estonian page, so it serves the primary-language one:
    # that is the text the visitor accepted, not our bundled translation.
    test "a language with no generated page records the store's primary-language page" do
      record = Legal.policy_record("et")
      assert record["template_versions"]["privacy-policy"] == "sha256:primary0000"
      assert record["policy_locale"] == "en"
    end

    test "without a page store the bundled template is what the host serves" do
      Application.put_env(
        :phoenix_kit_legal,
        :page_store,
        PhoenixKit.Modules.Legal.PageStore.None
      )

      record = Legal.policy_record("et")
      refute record["template_versions"]["privacy-policy"] == "sha256:primary0000"
      assert record["policy_locale"] == "et"
    end
  end

  test "generated_page_templates/0 keys every page by language only" do
    with_settings(fn ->
      Repo.query!(
        "INSERT INTO phoenix_kit_settings (key, value_json) VALUES ('legal_page_templates', $1)",
        [%{"privacy-policy" => %{"_primary" => "en", "en" => %{"locale" => "en"}}}]
      )

      assert Legal.generated_page_templates() == %{
               "privacy-policy" => %{"en" => %{"locale" => "en"}}
             }
    end)
  end

  test "put_page_record/5 records the entry and the store's primary language" do
    current = %{"privacy-policy" => "junk", "cookie-policy" => %{"en" => %{}}}
    entry = %{"locale" => "en", "template_version" => "sha256:x"}

    assert %{
             "privacy-policy" => %{"_primary" => "et", "de" => ^entry},
             "cookie-policy" => %{"en" => %{}}
           } = Legal.put_page_record(current, "privacy-policy", "de", entry, fn -> "et" end)

    # No store language (or a failing lookup): no "_primary".
    refute Legal.put_page_record(%{}, "p", "de", entry, fn -> nil end)["p"]["_primary"]
    refute Legal.put_page_record(%{}, "p", "de", entry, fn -> raise "down" end)["p"]["_primary"]
  end

  test "clean_locale/1 keeps language codes only" do
    assert Legal.clean_locale("et") == "et"
    assert Legal.clean_locale(" zh_Hant ") == "zh_Hant"
    assert Legal.clean_locale("e") == nil
    assert Legal.clean_locale(String.duplicate("a", 40)) == nil
    assert Legal.clean_locale(42) == nil
  end
end
