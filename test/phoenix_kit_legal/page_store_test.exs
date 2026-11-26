defmodule PhoenixKit.Modules.Legal.PageStoreTest do
  @moduledoc """
  Publishing is optional: the page store is Publishing when it is installed
  (this repo's own deps have it), a host module when configured, and
  `PageStore.None` otherwise.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.PageStore

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_legal, :page_store) end)
    :ok
  end

  test "Publishing is the store when it is installed" do
    assert PageStore.publishing_installed?()
    assert PageStore.adapter() == PageStore.Publishing
    assert PageStore.available?()
  end

  test "a configured store wins" do
    Application.put_env(:phoenix_kit_legal, :page_store, PageStore.None)
    assert PageStore.adapter() == PageStore.None
    refute PageStore.available?()
  end

  @tag :capture_log
  test "a misconfigured store is ignored, never crashes" do
    for bad <- [false, true, "MyApp.Store", Nope.NotAModule, Enum] do
      Application.put_env(:phoenix_kit_legal, :page_store, bad)
      assert PageStore.adapter() == PageStore.Publishing, "#{inspect(bad)}"
    end
  end

  test "a misconfigured store is logged once, not on every call" do
    Application.put_env(:phoenix_kit_legal, :page_store, Nope.LoggedOnce)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..5, do: PageStore.adapter()
      end)

    assert length(String.split(log, "Nope.LoggedOnce")) - 1 <= 1
  end

  test "None stores nothing and says so" do
    none = PageStore.None
    refute none.enabled?()
    assert none.get_primary_language() == "en"
    assert none.list_posts("legal") == []
    assert {:error, :not_found} = none.read_post("legal", "privacy-policy")
    assert {:error, :publishing_unavailable} = none.create_post("legal", %{})
    assert {:error, :publishing_unavailable} = none.publish_version("legal", "x", 1, [])
  end

  test "both adapters implement every callback" do
    callbacks = PageStore.behaviour_info(:callbacks)

    for mod <- [PageStore.Publishing, PageStore.None],
        Code.ensure_loaded!(mod),
        {fun, arity} <- callbacks do
      assert function_exported?(mod, fun, arity), "#{inspect(mod)} lacks #{fun}/#{arity}"
    end
  end

  test "without a store, page generation is refused and nothing is listed" do
    Application.put_env(:phoenix_kit_legal, :page_store, PageStore.None)
    PhoenixKit.Cache.put(:settings, "legal_frameworks", ~s({"items": ["gdpr"]}))

    assert {:error, :publishing_unavailable} = Legal.generate_page("privacy-policy")
    assert Legal.list_generated_pages() == []
  end

  test "mix.exs declares Publishing optional" do
    deps = Mix.Project.config()[:deps]

    assert {:phoenix_kit_publishing, _req, opts} = List.keyfind(deps, :phoenix_kit_publishing, 0)
    assert opts[:optional] == true
  end
end
