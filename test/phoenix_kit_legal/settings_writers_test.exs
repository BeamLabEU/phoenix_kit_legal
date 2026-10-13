defmodule PhoenixKit.Modules.Legal.SettingsWritersTest do
  @moduledoc """
  Every settings writer says who made the change.

  Core keeps a history of settings (`PhoenixKit.Settings.History`) that
  records `:actor_uuid` and `:source` for each write. A writer that drops its
  options leaves that history saying "system" for a change a person made.

  No database stands behind the settings in this suite, so the writes go to
  `SettingsRecorder`, which reports what would have been written.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Test.SettingsRecorder
  alias PhoenixKitWeb.Live.Modules.Legal.Settings, as: SettingsLive

  @actor "018e3c4a-1234-7678-abcd-ef1234567890"
  @opts [actor_uuid: @actor, source: "settings"]

  setup do
    SettingsRecorder.install()
  end

  describe "Legal's writers" do
    # {call, kind, key, value}
    @writers [
      {{:set_frameworks, [["gdpr", "nonsense", "ccpa"]]}, :json, "legal_frameworks",
       %{"items" => ["gdpr", "ccpa"]}},
      {{:enable_consent_widget, []}, :boolean, "legal_consent_widget_enabled", true},
      {{:disable_consent_widget, []}, :boolean, "legal_consent_widget_enabled", false},
      {{:update_icon_position, ["top-left"]}, :string, "legal_cookie_banner_position",
       "top-left"},
      {{:update_policy_version, ["2.0"]}, :string, "legal_policy_version", "2.0"},
      {{:enable_google_consent_mode, []}, :boolean, "legal_google_consent_mode", true},
      {{:disable_google_consent_mode, []}, :boolean, "legal_google_consent_mode", false},
      {{:update_consent_mode, ["notice"]}, :string, "legal_consent_mode", "notice"},
      {{:update_hide_for_authenticated, [false]}, :boolean, "legal_hide_for_authenticated", false}
    ]

    for {{function, args}, kind, key, value} <- @writers do
      test "#{function} passes its options on, and still works without any" do
        expected = %{
          kind: unquote(kind),
          key: unquote(key),
          value: unquote(Macro.escape(value)),
          module: "legal"
        }

        assert {:ok, _} = apply(Legal, unquote(function), unquote(Macro.escape(args)) ++ [@opts])
        assert SettingsRecorder.written() == [Map.put(expected, :opts, @opts)]

        assert {:ok, _} = apply(Legal, unquote(function), unquote(Macro.escape(args)))
        assert SettingsRecorder.written() == [Map.put(expected, :opts, [])]
      end
    end

    test "the two that read the stored value first take options too" do
      # They merge into what is stored, which needs a database to read, so
      # only their shape can be checked here.
      Code.ensure_loaded!(Legal)

      for function <- [:update_company_info, :update_dpo_contact] do
        assert function_exported?(Legal, function, 1)
        assert function_exported?(Legal, function, 2)
      end
    end

    test "a refused value is refused before anything is written, with or without options" do
      for {function, args, reason} <- [
            {:update_icon_position, ["middle"], :invalid_position},
            {:update_consent_mode, ["loose"], :invalid_mode},
            {:update_policy_version, [String.duplicate("9", 21)], :version_too_long}
          ] do
        assert apply(Legal, function, args) == {:error, reason}
        assert apply(Legal, function, args ++ [@opts]) == {:error, reason}
      end

      assert SettingsRecorder.written() == []
    end
  end

  describe "remembering what the cookie policy was generated from" do
    alias PhoenixKit.Users.Auth.Scope

    test "names whoever generated the page" do
      scope = %Scope{authenticated?: true, user: %{uuid: @actor}}

      assert Legal.remember_collection("cookie-policy", scope) == :ok

      assert [
               %{
                 kind: :string,
                 key: "legal_policy_collection_fingerprint",
                 module: "legal",
                 opts: [actor_uuid: @actor]
               }
             ] = SettingsRecorder.written()
    end

    test "names nobody when there is no scope, or no user in it" do
      for scope <- [nil, %Scope{authenticated?: false, user: nil}] do
        assert Legal.remember_collection("cookie-policy", scope) == :ok

        assert [%{key: "legal_policy_collection_fingerprint", opts: []}] =
                 SettingsRecorder.written()
      end
    end

    test "only the cookie policy is written from the list" do
      scope = %Scope{authenticated?: true, user: %{uuid: @actor}}

      for page <- ["privacy-policy", "terms-of-service", "do-not-sell"] do
        assert Legal.remember_collection(page, scope) == :ok
      end

      assert SettingsRecorder.written() == []
    end
  end

  describe "the settings page" do
    setup do
      for {key, value} <- [
            # Off, so nothing on these paths reads a legal page or a framework
            # from the database.
            {"legal_enabled", "false"},
            {"legal_consent_widget_enabled", "true"},
            {"legal_hidden_collection", %{"items" => ["shop.cart"]}},
            {"legal_policy_collection_fingerprint", ""},
            {"legal_consent_cookie_days", "180"}
          ],
          do: PhoenixKit.Cache.put(:settings, key, value)

      :ok
    end

    defp socket(assigns) do
      scope = %PhoenixKit.Users.Auth.Scope{authenticated?: true, user: %{uuid: @actor}}

      base = %{
        __changed__: %{},
        flash: %{},
        phoenix_kit_current_scope: scope,
        selected_frameworks: ["gdpr"],
        hidden_collection: ["shop.cart"],
        consent_widget_enabled: true
      }

      %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns)}
    end

    defp consent_form(overrides \\ %{}) do
      Map.merge(
        %{
          "consent_mode" => "strict",
          "icon_position" => "bottom-left",
          "hide_for_authenticated" => "true",
          "google_consent_mode" => "true",
          "consent_log" => "true",
          "consent_cookie_days" => "90"
        },
        overrides
      )
    end

    test "every write an event makes carries the signed-in admin" do
      for {event, params} <- [
            {"toggle_framework", %{"id" => "ccpa"}},
            {"toggle_collection", %{"key" => "shop.cart"}},
            {"toggle_collection", %{"key" => "shop.ads"}},
            {"toggle_consent_widget", %{}},
            {"save_consent_settings", consent_form()}
          ] do
        assert {:noreply, socket} = SettingsLive.handle_event(event, params, socket(%{}))
        refute socket.assigns.flash["error"], "#{event}: #{inspect(socket.assigns.flash)}"

        writes = SettingsRecorder.written()
        assert writes != [], event

        for write <- writes do
          assert write.opts[:actor_uuid] == @actor, "#{event} wrote #{write.key} with no actor"
          assert write.opts[:source] == "settings", "#{event} wrote #{write.key} as the system"
          assert write.module == "legal"
        end
      end
    end

    test "saving the consent settings writes all of them" do
      assert {:noreply, _socket} =
               SettingsLive.handle_event("save_consent_settings", consent_form(), socket(%{}))

      assert SettingsRecorder.written() |> Enum.map(&{&1.key, &1.value}) |> Enum.sort() == [
               {"legal_consent_cookie_days", "90"},
               {"legal_consent_log_enabled", "true"},
               {"legal_consent_log_ip", "false"},
               {"legal_consent_log_user_agent", "false"},
               {"legal_consent_mode", "strict"},
               {"legal_consent_reload_on_withdrawal", "false"},
               {"legal_cookie_banner_position", "bottom-left"},
               {"legal_google_consent_mode", true},
               {"legal_hide_for_authenticated", true}
             ]
    end

    test "a number of days that cannot be right is said, and nothing is saved" do
      for days <- ["0", "731", "abc", "", "3.5"] do
        form = consent_form(%{"consent_cookie_days" => days})

        assert {:noreply, socket} =
                 SettingsLive.handle_event("save_consent_settings", form, socket(%{}))

        assert socket.assigns.flash["error"] ==
                 "Enter a whole number of days from 1 to 730. Nothing was saved."

        # Not the consent mode, not the icon position: nothing.
        assert SettingsRecorder.written() == [], inspect(days)
      end
    end

    test "nobody signed in is still a change made on the settings page" do
      assert {:noreply, _socket} =
               SettingsLive.handle_event(
                 "toggle_collection",
                 %{"key" => "shop.ads"},
                 socket(%{phoenix_kit_current_scope: nil})
               )

      assert [%{opts: opts}] = SettingsRecorder.written()
      assert opts == [source: "settings"]
    end
  end
end
