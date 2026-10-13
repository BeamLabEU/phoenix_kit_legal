defmodule PhoenixKit.Modules.Legal.DataCollectionTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.DataCollection
  alias PhoenixKit.Modules.Legal.Test.SettingsRecorder

  defmodule Declaring do
    def module_key, do: "shop"

    def data_collection do
      [
        %{
          key: "shop.cart",
          title: "Your basket",
          description: "  What you put in it.  ",
          category: "necessary",
          mode: :always,
          active: true,
          data: ["Products", "", 7],
          retention: "30 days",
          storage: [%{name: "cart", kind: "cookie", duration: "30 days", purpose: "Basket"}, %{}]
        },
        %{
          "key" => "shop.ads",
          "title" => "Advertising",
          "category" => :marketing,
          "mode" => "consent",
          "active" => false
        },
        # Neither of these is a declaration.
        %{key: "shop.untitled"},
        "not a map"
      ]
    end
  end

  defmodule Raising do
    def module_key, do: "broken"
    def data_collection, do: raise("nope")
  end

  defmodule Silent do
    def module_key, do: "quiet"
  end

  defmodule Exiting do
    def module_key, do: "gone"
    def data_collection, do: exit(:database_down)
  end

  # Declares the locale it is asked in — through a backend of its own, the
  # way a real module's `gettext/1` looks its locale up.
  defmodule Localized do
    def module_key, do: "localized"

    def data_collection do
      [
        %{
          key: "localized.entry",
          title: Gettext.get_locale(PhoenixKitWeb.Gettext),
          description: Gettext.get_locale(PhoenixKit.Modules.Legal.Gettext),
          retention: Gettext.get_locale()
        }
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

  defmodule Switched do
    def module_key, do: "switched"

    def data_collection do
      [
        %{key: "switched.on", title: "On", mode: :consent},
        %{key: "switched.off", title: "Off", mode: :off},
        %{key: "switched.inactive", title: "Inactive", mode: :consent, active: false}
      ]
    end
  end

  # One declaration built from whatever a test puts in the process dictionary
  # of the process that evaluates it — `collect/1` runs in the caller.
  defmodule Shaped do
    def module_key, do: "shaped"
    def data_collection, do: Process.get(:shaped_declarations, [])
  end

  defp shaped(declaration) do
    Process.put(:shaped_declarations, [declaration])
    DataCollection.collect([Shaped])
  end

  setup do
    PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => []})
    PhoenixKit.Cache.put(:settings, "legal_consent_widget_enabled", "true")
    :ok
  end

  describe "collect/1" do
    test "normalises what modules declare and drops what is not a declaration" do
      assert [cart, ads] = DataCollection.collect([Declaring, Raising, Silent])

      assert cart == %{
               key: "shop.cart",
               module: "shop",
               title: "Your basket",
               description: "What you put in it.",
               category: "necessary",
               mode: :always,
               active: true,
               data: ["Products"],
               retention: "30 days",
               storage: [%{name: "cart", kind: "cookie", duration: "30 days", purpose: "Basket"}]
             }

      assert %{key: "shop.ads", category: "marketing", mode: :consent, active: false, storage: []} =
               ads
    end

    test "a module that raises declares nothing and breaks nobody else" do
      {entries, log} =
        ExUnit.CaptureLog.with_log(fn ->
          DataCollection.collect([Raising, Exiting, Declaring])
        end)

      assert [_, _] = entries

      # It is named, so the operator can tell whose declaration is missing…
      assert log =~ "DataCollectionTest.Raising.data_collection/0 failed (RuntimeError)"
      assert log =~ "DataCollectionTest.Exiting.data_collection/0 failed (exit)"
      # …without the error's own text or a stacktrace.
      refute log =~ "nope"
      refute log =~ "database_down"
      refute log =~ "data_collection_test.exs:"
    end

    test "a module with nothing to declare is not a failure" do
      {entries, log} = ExUnit.CaptureLog.with_log(fn -> DataCollection.collect([Silent]) end)

      assert entries == []
      refute log =~ "failed"
    end

    test "a key declared twice is listed once" do
      assert [_, _] = DataCollection.collect([Declaring, Declaring])
    end
  end

  describe "normalising a declaration" do
    test "the key and the title must be text, under an atom or a string key" do
      for {declaration, kept?} <- [
            {%{key: "a", title: "A"}, true},
            {%{"key" => "a", "title" => "A"}, true},
            {%{"key" => "a", title: "A"}, true},
            {%{key: " a ", title: " A "}, true},
            # A key that is not text is no key: the operator's choice is stored by it.
            {%{key: :a, title: "A"}, false},
            {%{key: 1, title: "A"}, false},
            {%{key: nil, title: "A"}, false},
            {%{key: "", title: "A"}, false},
            {%{key: "   ", title: "A"}, false},
            {%{key: "a", title: :a}, false},
            {%{key: "a", title: ""}, false},
            {%{key: "a"}, false},
            {%{title: "A"}, false},
            {%{}, false},
            {[key: "a", title: "A"], false},
            {nil, false}
          ] do
        case shaped(declaration) do
          [entry] ->
            assert kept?, "kept #{inspect(declaration)}"
            assert %{key: "a", title: "A", module: "shaped"} = entry

          [] ->
            refute kept?, "dropped #{inspect(declaration)}"
        end
      end
    end

    test "the category defaults to analytics: the one that asks before collecting" do
      for {category, expected} <- [
            {"necessary", "necessary"},
            {"analytics", "analytics"},
            {"marketing", "marketing"},
            {"preferences", "preferences"},
            {:necessary, "necessary"},
            {:marketing, "marketing"},
            {"Necessary", "analytics"},
            {"essential", "analytics"},
            {:essential, "analytics"},
            {"", "analytics"},
            {nil, "analytics"},
            {7, "analytics"},
            {:missing, "analytics"}
          ],
          key <- [:category, "category"] do
        declaration =
          if category == :missing,
            do: %{key: "a", title: "A"},
            else: %{key => category, key: "a", title: "A"}

        assert [%{category: ^expected}] = shaped(declaration), inspect({key, category})
      end
    end

    test "the mode defaults to :always: collected, and said to be" do
      for {mode, expected} <- [
            {:always, :always},
            {:consent, :consent},
            {:unless_objected, :unless_objected},
            {:off, :off},
            {"always", :always},
            {"consent", :consent},
            {"unless_objected", :unless_objected},
            {"off", :off},
            {"Consent", :always},
            {"opt-in", :always},
            {:opt_in, :always},
            {"", :always},
            {nil, :always},
            {true, :always},
            {:missing, :always}
          ],
          key <- [:mode, "mode"] do
        declaration =
          if mode == :missing,
            do: %{key: "a", title: "A"},
            else: %{key => mode, key: "a", title: "A"}

        assert [%{mode: ^expected}] = shaped(declaration), inspect({key, mode})
      end
    end

    test "only a strict false makes an entry inactive" do
      for {active, expected} <- [
            {true, true},
            {false, false},
            {nil, true},
            {"false", true},
            {0, true},
            {:missing, true}
          ],
          key <- [:active, "active"] do
        declaration =
          if active == :missing,
            do: %{key: "a", title: "A"},
            else: %{key => active, key: "a", title: "A"}

        assert [%{active: ^expected}] = shaped(declaration), inspect({key, active})
      end
    end

    test "everything else has an empty default" do
      assert [entry] = shaped(%{key: "a", title: "A"})

      assert %{description: "", data: [], retention: nil, storage: []} = entry

      assert [%{data: [], retention: nil, storage: [%{name: "c", kind: "cookie", duration: ""}]}] =
               shaped(%{
                 key: "a",
                 title: "A",
                 data: "not a list",
                 retention: "  ",
                 storage: [%{name: "c"}, %{kind: "cookie"}, "c", nil]
               })
    end
  end

  describe "hidden_keys/0" do
    test "is the stored list of keys, and nothing for anything malformed" do
      for {stored, expected} <- [
            {%{"items" => ["a", "b"]}, ["a", "b"]},
            {%{"items" => []}, []},
            {%{"items" => "x"}, []},
            {%{"items" => [1, nil, "a"]}, ["a"]},
            {%{"items" => nil}, []},
            {%{"other" => ["a"]}, []},
            {%{}, []},
            {["a"], []},
            {"a", []},
            {nil, []}
          ] do
        PhoenixKit.Cache.put(:settings, "legal_hidden_collection", stored)
        assert DataCollection.hidden_keys() == expected, inspect(stored)
      end
    end
  end

  describe "hide/2 and show/2" do
    setup do
      SettingsRecorder.install()
    end

    test "write the sorted list of hidden keys, with who made the change" do
      opts = [actor_uuid: "018e3c4a-1234-7678-abcd-ef1234567890", source: "settings"]
      SettingsRecorder.seed("legal_hidden_collection", %{"items" => ["shop.cart"]})

      assert DataCollection.hide("a.first", opts) == {:ok, ["a.first", "shop.cart"]}
      assert DataCollection.show("shop.cart", opts) == {:ok, ["a.first"]}
      assert DataCollection.hide("shop.cart") == {:ok, ["a.first", "shop.cart"]}

      assert [
               %{
                 kind: :json,
                 key: "legal_hidden_collection",
                 value: %{"items" => ["a.first", "shop.cart"]},
                 module: "legal",
                 opts: ^opts
               },
               %{value: %{"items" => ["a.first"]}, opts: ^opts},
               %{value: %{"items" => ["a.first", "shop.cart"]}, opts: []}
             ] = SettingsRecorder.written()
    end

    # The settings cache trails a write. A toggle that read the list through
    # it would start from the list as it was, and the second click of a pair
    # would repeat the first instead of undoing it.
    test "start from the stored list, not from a cache that has not caught up" do
      PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => []})
      SettingsRecorder.seed("legal_hidden_collection", %{"items" => ["shop.cart"]})

      assert DataCollection.show("shop.cart") == {:ok, []}
      assert DataCollection.hidden_keys(fresh: true) == []
      # The cached read is still the old one; nothing here depends on it.
      assert DataCollection.hidden_keys() == []
    end

    test "hiding twice hides once" do
      assert DataCollection.hide("shop.cart") == {:ok, ["shop.cart"]}
      assert DataCollection.hide("shop.cart") == {:ok, ["shop.cart"]}
    end
  end

  describe "fetch_declared/2" do
    setup do
      previous = {Gettext.get_locale(), Gettext.get_locale(PhoenixKitWeb.Gettext)}

      on_exit(fn ->
        {global, _backend} = previous
        Gettext.put_locale(global)
      end)

      :ok
    end

    test "is in the language asked for, for every backend, whatever the caller's locales" do
      # What an admin page looks like: core has set a locale for its own
      # backend, which wins over the global one in this process.
      Gettext.put_locale("fr")
      Gettext.put_locale(PhoenixKitWeb.Gettext, "de")
      Gettext.put_locale(PhoenixKit.Modules.Legal.Gettext, "ru")

      assert {:ok, [entry]} = DataCollection.fetch_declared("et", modules: [Localized])
      assert %{title: "et", description: "et", retention: "et"} = entry

      # And the caller's own locales are as they were.
      assert Gettext.get_locale() == "fr"
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "de"
      assert Gettext.get_locale(PhoenixKit.Modules.Legal.Gettext) == "ru"
    end

    test "says so when the declarations do not arrive in time" do
      assert DataCollection.fetch_declared("en", modules: [Slow], timeout: 20) ==
               {:error, :timeout}

      # Nothing of the abandoned attempt is left in the caller's mailbox.
      refute_receive _, 50
    end

    test "declared/1 is the same answer, raising where that one is an error" do
      # No module registry runs in this suite: nothing is declared, which is
      # an answer and not a failure.
      assert DataCollection.fetch_declared("en") == {:ok, []}
      assert DataCollection.declared("en") == []
    end
  end

  describe "listed/1" do
    test "leaves out what is switched off, like what is inactive" do
      entries = DataCollection.collect([Switched])

      assert [%{key: "switched.on"}] = DataCollection.listed(entries)
      assert [_, _, _] = entries
    end

    test "is what is active and not hidden" do
      entries = DataCollection.collect([Declaring])
      assert [%{key: "shop.cart"}] = DataCollection.listed(entries)

      PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => ["shop.cart"]})
      assert DataCollection.listed(entries) == []
    end

    test "by_category/1 always has every category" do
      grouped =
        [Declaring]
        |> DataCollection.collect()
        |> DataCollection.listed()
        |> DataCollection.by_category()

      assert Map.keys(grouped) |> Enum.sort() == ~w(analytics marketing necessary preferences)
      assert [%{key: "shop.cart"}] = grouped["necessary"]
      assert grouped["analytics"] == []
    end
  end

  describe "warnings/2" do
    setup do
      [cart, ads] = DataCollection.collect([Declaring])
      %{cart: cart, ads: %{ads | active: true}}
    end

    test "nothing to say about an entry that is shown and can be collected", %{cart: cart} do
      assert DataCollection.warnings(cart, hidden: [], widget_enabled: true) == []
    end

    test "says so when something collected is not disclosed", %{cart: cart} do
      assert [warning] =
               DataCollection.warnings(cart, hidden: ["shop.cart"], widget_enabled: true)

      assert warning =~ "not told"
    end

    test "says so when consent is awaited and nothing asks for it", %{ads: ads} do
      assert [warning] = DataCollection.warnings(ads, hidden: [], widget_enabled: false)
      assert warning =~ "banner is off"
    end

    test "an inactive entry needs no attention", %{ads: ads} do
      assert DataCollection.warnings(%{ads | active: false},
               hidden: ["shop.ads"],
               widget_enabled: false
             ) == []
    end
  end

  describe "fingerprint/1" do
    test "changes when anything the policy prints about what is collected changes" do
      [cart, _ads] = DataCollection.collect([Declaring])
      [item] = cart.storage
      original = DataCollection.fingerprint([cart])

      assert DataCollection.fingerprint([cart]) == original

      for {what, changed} <- [
            {"key", %{cart | key: "shop.basket"}},
            {"mode", %{cart | mode: :consent}},
            {"category", %{cart | category: "preferences"}},
            {"retention", %{cart | retention: "90 days"}},
            {"data", %{cart | data: ["Products", "Quantities"]}},
            {"no data", %{cart | data: []}},
            {"storage name", %{cart | storage: [%{item | name: "basket"}]}},
            {"storage kind", %{cart | storage: [%{item | kind: "localStorage"}]}},
            {"storage duration", %{cart | storage: [%{item | duration: "60 days"}]}},
            {"no storage", %{cart | storage: []}}
          ] do
        assert DataCollection.fingerprint([changed]) != original, what
      end

      assert DataCollection.fingerprint([]) != original
    end

    test "wording alone is not a change of what is collected" do
      [cart, _ads] = DataCollection.collect([Declaring])
      [item] = cart.storage
      original = DataCollection.fingerprint([cart])

      for reworded <- [
            %{cart | title: "Your shopping basket"},
            %{cart | description: "Reworded."},
            %{cart | storage: [%{item | purpose: "Holds the basket"}]}
          ] do
        assert DataCollection.fingerprint([reworded]) == original
      end
    end
  end

  describe "fingerprint/0" do
    setup do
      previous = Gettext.get_locale()
      on_exit(fn -> Gettext.put_locale(previous) end)

      for {key, value} <- [
            {"legal_consent_log_enabled", "true"},
            {"legal_consent_cookie_days", "90"}
          ],
          do: PhoenixKit.Cache.put(:settings, key, value)

      :ok
    end

    test "the same list hashes differently in two languages, which is why one is fixed" do
      {:ok, english} = DataCollection.fetch_declared("en", modules: [Legal])
      {:ok, german} = DataCollection.fetch_declared("de", modules: [Legal])

      # The storage durations and the data list are translated text.
      assert DataCollection.fingerprint(english) != DataCollection.fingerprint(german)
    end

    # No module registry runs in this suite, so `fingerprint/0` has nothing
    # declared to hash here; what makes it language-proof is shown by the
    # `fetch_declared/2` tests above. This one pins that the stored value and
    # the comparison are taken the same way under any locale.
    test "does not depend on the viewer's language" do
      Gettext.put_locale("en")
      english_viewer = DataCollection.fingerprint()

      Gettext.put_locale("de")
      Gettext.put_locale(PhoenixKit.Modules.Legal.Gettext, "ru")

      assert DataCollection.fingerprint() == english_viewer

      PhoenixKit.Cache.put(:settings, "legal_policy_collection_fingerprint", english_viewer)
      refute DataCollection.policy_outdated?()
    end
  end

  describe "remember_generated/1" do
    test "stores the fingerprint of what is listed" do
      SettingsRecorder.install()

      assert {:ok, _} = DataCollection.remember_generated()

      assert [%{kind: :string, key: "legal_policy_collection_fingerprint", value: value}] =
               SettingsRecorder.written()

      assert value == DataCollection.fingerprint()
    end
  end

  describe "policy_outdated?/1" do
    setup do
      PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => []})
      {:ok, entries} = DataCollection.fetch_declared("en", modules: [Declaring])
      {:ok, entries: entries}
    end

    # The cache trails a write: a page that has just hidden an entry must be
    # able to say what it knows rather than be handed the list from before.
    test "compares with the hidden list it is given, not the cached one", %{entries: entries} do
      PhoenixKit.Cache.put(
        :settings,
        "legal_policy_collection_fingerprint",
        entries |> DataCollection.listed() |> DataCollection.fingerprint()
      )

      refute DataCollection.policy_outdated?(modules: [Declaring])
      assert DataCollection.policy_outdated?(modules: [Declaring], hidden: ["shop.cart"])
    end

    test "reads the stored fingerprint from the setting itself when asked", %{entries: entries} do
      SettingsRecorder.install()
      current = entries |> DataCollection.listed() |> DataCollection.fingerprint()

      # The cache still holds what was stored before the policy was regenerated.
      PhoenixKit.Cache.put(:settings, "legal_policy_collection_fingerprint", "0000000000000000")
      SettingsRecorder.seed_setting("legal_policy_collection_fingerprint", current)

      assert DataCollection.policy_outdated?(modules: [Declaring])
      refute DataCollection.policy_outdated?(modules: [Declaring], fresh: true)
    end
  end

  describe "listed/2" do
    test "takes the hidden keys from the caller when it has them" do
      {:ok, entries} = DataCollection.fetch_declared("en", modules: [Declaring])
      PhoenixKit.Cache.put(:settings, "legal_hidden_collection", %{"items" => []})

      assert [%{key: "shop.cart"}] = DataCollection.listed(entries)
      assert [] = DataCollection.listed(entries, hidden: ["shop.cart"])
    end
  end

  describe "policy_outdated?/0" do
    test "is false until a policy was generated from a list" do
      PhoenixKit.Cache.put(:settings, "legal_policy_collection_fingerprint", "")
      refute DataCollection.policy_outdated?()
    end

    test "is true once the list no longer matches what was generated" do
      PhoenixKit.Cache.put(:settings, "legal_policy_collection_fingerprint", "0000000000000000")
      assert DataCollection.policy_outdated?()

      PhoenixKit.Cache.put(
        :settings,
        "legal_policy_collection_fingerprint",
        DataCollection.fingerprint()
      )

      refute DataCollection.policy_outdated?()
    end
  end

  describe "the module's own declaration" do
    setup do
      for {key, value} <- [
            {"legal_consent_log_enabled", "true"},
            {"legal_consent_log_ip", "false"},
            {"legal_consent_log_user_agent", "false"},
            {"legal_consent_cookie_days", "90"}
          ],
          do: PhoenixKit.Cache.put(:settings, key, value)

      :ok
    end

    test "names the consent cookie, necessary and always on" do
      assert [entry] = DataCollection.collect([Legal])

      assert %{key: "legal.consent", module: "legal", category: "necessary", mode: :always} =
               entry

      assert [
               %{name: "pk_consent", kind: "cookie", duration: "90 days"},
               %{name: "pk_consent", kind: "localStorage"}
               | _
             ] = entry.storage

      refute Enum.any?(entry.data, &(&1 =~ "IP address"))
    end

    test "names every key the banner script writes to the browser's storage" do
      assert [entry] = DataCollection.collect([Legal])
      declared = for %{kind: kind, name: name} <- entry.storage, kind =~ "Storage", do: name

      source =
        :phoenix_kit_legal
        |> :code.priv_dir()
        |> Path.join("static/assets/phoenix_kit_consent.js")
        |> File.read!()

      # Every `const SOMETHING_KEY = "pk_…"` the script declares.
      written = Regex.scan(~r/const \w+_KEY = "(pk_[a-z_]+)";/, source, capture: :all_but_first)

      assert length(written) >= 5
      assert Enum.sort(List.flatten(written)) == Enum.sort(declared)
      assert "pk_consent_version" in declared
    end

    test "says the address is kept only when the setting keeps it" do
      PhoenixKit.Cache.put(:settings, "legal_consent_log_ip", "true")
      assert [entry] = DataCollection.collect([Legal])
      assert Enum.any?(entry.data, &(&1 =~ "IP address"))
    end

    test "is inactive while the banner is off" do
      PhoenixKit.Cache.put(:settings, "legal_consent_widget_enabled", "false")
      assert [%{active: false}] = DataCollection.collect([Legal])
    end
  end
end

defmodule PhoenixKit.Modules.Legal.JsSourcesTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Routes

  test "the consent manager ships in the host's module bundle" do
    assert [%{app: :phoenix_kit_legal, file: file, global: "PhoenixKitLegalHooks"}] =
             Legal.js_sources()

    path = Path.join(:code.priv_dir(:phoenix_kit_legal), file)
    source = File.read!(path)

    # The global the bundle compiler folds into the host's hooks.
    assert source =~ "window.PhoenixKitLegalHooks = { CookieConsent: CookieConsentHook }"
    # It retires core's older bundled copy instead of deferring to it.
    assert source =~ "if (previous && previous.reportsDecisions) return;"
    assert source =~ "window.PHOENIX_KIT_CONSENT_AVAILABLE = false;"
  end

  test "the script keeps the server's copy in step with the browser's" do
    [%{file: file}] = Legal.js_sources()
    source = File.read!(Path.join(:code.priv_dir(:phoenix_kit_legal), file))

    # On load the server is asked what it holds, and told when that differs…
    assert source =~ "function reconcileWithServer(consent)"
    assert source =~ "reconcileWithServer(stored);"

    assert source =~
             "if (!server.decided || server.version !== PhoenixKitConsent.config.policyVersion) {"

    # …the newer copy winning, in either direction…
    assert source =~
             "if (server.decided_at > decidedAt(consent)) return adoptServerConsent(server);"

    # …and tried again on the next page when it could not be done.
    assert source =~ "if (!recorded) setReconciled(false);"
    assert source =~ "}).catch(function(err) {\n      setReconciled(false);"
    # …once per session, not on every page…
    assert source =~ "if (reconciledAlready()) return;\n    setReconciled(true);"
    assert source =~ ~s(const SYNCED_KEY = "pk_consent_synced";)
    # …and never on the strength of a cookie merely being there.
    refute source =~ "hasServerCookie"
    refute source =~ "document.cookie"
    # …a revocation is retried until the server has heard it…
    assert source =~ ~s(const REVOKE_PENDING_KEY = "pk_consent_revoke_pending";)
    assert source =~ "if (forgotten) setRevokePending(false);"
    assert source =~ "revokeOnServer().then("
    # …carries its time, and never deletes a decision the server took later…
    assert source =~ "localStorage.setItem(REVOKE_PENDING_KEY, String(Date.now()));"
    assert source =~ "if (!server.decided || server.decided_at * 1000 > since) {"
    # …and stops once the endpoint is gone.
    assert source =~ "return response.ok || response.status === 404;"

    # A revocation in another tab — or cleared storage — is applied here as
    # a refusal of everything.
    assert source =~
             "if (e.key === null || (e.key === STORAGE_KEY && e.newValue === null)) {"
  end

  test "the route module carries the consent endpoint and nothing else" do
    assert Legal.route_module() == Routes

    routes = Macro.to_string(Routes.generate("/phoenix_kit"))

    for verb <- ~w(get post delete), do: assert(routes =~ ~s[#{verb}("/api/consent"])
    assert routes =~ "pipe_through([:phoenix_kit_api])"
    refute function_exported?(Routes, :admin_routes, 0)
  end
end
