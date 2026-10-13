defmodule PhoenixKit.Modules.Legal.DataCollectionTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.DataCollection

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
      assert [_, _] = DataCollection.collect([Raising, Declaring])
    end

    test "a key declared twice is listed once" do
      assert [_, _] = DataCollection.collect([Declaring, Declaring])
    end
  end

  describe "listed/1" do
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
    test "changes when what visitors are told would change" do
      [cart, _ads] = DataCollection.collect([Declaring])
      original = DataCollection.fingerprint([cart])

      assert DataCollection.fingerprint([cart]) == original
      assert DataCollection.fingerprint([%{cart | mode: :consent}]) != original
      assert DataCollection.fingerprint([%{cart | retention: "90 days"}]) != original
      assert DataCollection.fingerprint([]) != original
      # Wording alone is not a change of what is collected.
      assert DataCollection.fingerprint([%{cart | description: "Reworded."}]) == original
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

      assert [%{name: "pk_consent", kind: "cookie", duration: "90 days"}, %{kind: "localStorage"}] =
               entry.storage

      refute Enum.any?(entry.data, &(&1 =~ "IP address"))
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

  test "the route module carries the consent endpoint and nothing else" do
    assert Legal.route_module() == PhoenixKit.Modules.Legal.Routes

    routes = Macro.to_string(PhoenixKit.Modules.Legal.Routes.generate("/phoenix_kit"))

    for verb <- ~w(get post delete), do: assert(routes =~ ~s[#{verb}("/api/consent"])
    assert routes =~ "pipe_through([:phoenix_kit_api])"
    refute function_exported?(PhoenixKit.Modules.Legal.Routes, :admin_routes, 0)
  end
end
