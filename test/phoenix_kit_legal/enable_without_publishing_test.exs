defmodule PhoenixKit.Modules.Legal.EnableWithoutPublishingTest do
  @moduledoc """
  `enable_system/0` with no page store: the module enables on its own (the
  consent widget and log need no Publishing). Settings writes go to a
  session-local `phoenix_kit_settings` shadow inside a rolled-back
  transaction, as `render_page_test.exs` does.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.PageStore
  alias PhoenixKit.Modules.Legal.Test.Repo

  @moduletag :integration

  setup do
    previous = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, Repo)
    Application.put_env(:phoenix_kit_legal, :page_store, PageStore.None)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_legal, :page_store)

      if previous,
        do: Application.put_env(:phoenix_kit, :repo, previous),
        else: Application.delete_env(:phoenix_kit, :repo)
    end)

    :ok
  end

  defp with_settings(fun) do
    Repo.transaction(fn ->
      Repo.query!("""
      CREATE TEMP TABLE phoenix_kit_settings (
        uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        key varchar(255) NOT NULL UNIQUE,
        value text,
        value_json jsonb,
        module varchar(255),
        date_added timestamp(0) NOT NULL DEFAULT now(),
        date_updated timestamp(0) NOT NULL DEFAULT now()
      ) ON COMMIT DROP
      """)

      # The settings write records history in core's activity log.
      Repo.query!("""
      CREATE TEMP TABLE phoenix_kit_activities (
        uuid uuid PRIMARY KEY,
        action varchar(255), module varchar(255), mode varchar(255),
        actor_uuid uuid, resource_type varchar(255), resource_uuid uuid,
        target_uuid uuid, metadata jsonb, permanent boolean,
        inserted_at timestamp
      ) ON COMMIT DROP
      """)

      fun.()
      Repo.rollback(:done)
    end)
  end

  test "enables without Publishing, and creates no publishing group" do
    with_settings(fn ->
      assert {:ok, :enabled} = Legal.enable_system()

      assert %{rows: [["true"]]} =
               Repo.query!("SELECT value FROM phoenix_kit_settings WHERE key = 'legal_enabled'")
    end)
  end
end
