defmodule PhoenixKit.Modules.Legal.ConsentTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.Modules.Legal.Consent
  alias PhoenixKit.Modules.Legal.ConsentLog
  alias PhoenixKit.Modules.Legal.Test.SettingsRecorder
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageVerifier

  @secret String.duplicate("s", 64)

  setup do
    # No database in this suite: the log is off unless a test turns it on.
    for {key, value} <- [
          {"legal_consent_log_enabled", "false"},
          {"legal_consent_log_ip", "false"},
          {"legal_consent_log_user_agent", "false"},
          {"legal_consent_reload_on_withdrawal", "true"},
          {"legal_consent_cookie_days", "180"}
        ],
        do: PhoenixKit.Cache.put(:settings, key, value)

    :ok
  end

  defp request(headers \\ []) do
    conn = %{conn(:post, "/phoenix_kit/api/consent") | secret_key_base: @secret}
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  defp with_cookie(conn, value), do: put_req_header(conn, "cookie", "pk_consent=#{value}")

  # Signs a payload the way `Consent.encode/2` does, so a test can build a
  # cookie that module would not: one from an older version of the payload.
  defp sign(payload) do
    key = KeyGenerator.generate(@secret, "phoenix_kit_legal consent cookie", cache: Plug.Keys)
    MessageVerifier.sign(Jason.encode!(payload), key)
  end

  defp consent(attrs \\ %{}) do
    struct!(
      Consent,
      Map.merge(
        %{
          id: "visitor-1",
          version: "1.0",
          categories: %{"analytics" => true, "marketing" => false, "preferences" => false},
          source: "banner",
          decided_at: System.system_time(:second)
        },
        attrs
      )
    )
  end

  describe "decode/2" do
    test "reads back what encode/2 signed" do
      original = consent()
      assert {:ok, ^original} = original |> Consent.encode(@secret) |> Consent.decode(@secret)
    end

    test "refuses a value signed with another key" do
      value = Consent.encode(consent(), String.duplicate("x", 64))
      assert Consent.decode(value, @secret) == :none
    end

    test "refuses a payload edited after signing" do
      [head, _payload, signature] = consent() |> Consent.encode(@secret) |> String.split(".")

      # A current timestamp, so the only thing wrong with it is the signature
      # — a stale one would be refused for its age and prove nothing.
      payload = %{
        "id" => "x",
        "v" => "1.0",
        "c" => %{"analytics" => true},
        "t" => System.system_time(:second)
      }

      forged = Base.url_encode64(Jason.encode!(payload), padding: false)

      assert Consent.decode(Enum.join([head, forged, signature], "."), @secret) == :none
      # The same payload, signed, is a decision: it was the signature.
      assert {:ok, _} = Consent.decode(sign(payload), @secret)
    end

    test "a cookie issued before the user flag existed still reads, naming nobody" do
      payload = %{
        "id" => "visitor-1",
        "v" => "1.0",
        "c" => %{"analytics" => true},
        "s" => "banner",
        "t" => System.system_time(:second)
      }

      assert {:ok, %Consent{with_user: false, categories: %{"analytics" => true}}} =
               Consent.decode(sign(payload), @secret)
    end

    test "the user flag survives the cookie, and only a strict true sets it" do
      attributed = consent(%{with_user: true})
      assert {:ok, ^attributed} = attributed |> Consent.encode(@secret) |> Consent.decode(@secret)

      base = %{"id" => "x", "v" => "1.0", "c" => %{}, "t" => System.system_time(:second)}

      for {stored, expected} <- [{true, true}, {false, false}, {"true", false}, {1, false}] do
        assert {:ok, %Consent{with_user: ^expected}} =
                 base |> Map.put("u", stored) |> sign() |> Consent.decode(@secret)
      end
    end

    test "refuses a decision older than the cookie's lifetime" do
      old = consent(%{decided_at: System.system_time(:second) - 181 * 86_400})
      assert old |> Consent.encode(@secret) |> Consent.decode(@secret) == :none

      PhoenixKit.Cache.put(:settings, "legal_consent_cookie_days", "365")
      assert {:ok, _} = old |> Consent.encode(@secret) |> Consent.decode(@secret)
    end

    test "refuses a decision dated in the future" do
      future = consent(%{decided_at: System.system_time(:second) + 3_600})
      assert future |> Consent.encode(@secret) |> Consent.decode(@secret) == :none
    end

    test "is :none for anything that is not a signed value" do
      for value <- [nil, "", "true", "a.b.c", 42],
          do: assert(Consent.decode(value, @secret) == :none)

      assert Consent.decode(Consent.encode(consent(), @secret), nil) == :none
    end

    test "the payload is readable without the key" do
      [_head, payload, _signature] = consent() |> Consent.encode(@secret) |> String.split(".")

      assert %{"c" => %{"analytics" => true}} =
               payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    end
  end

  describe "status/2" do
    test "is :unknown without a cookie" do
      assert Consent.status(request(), "analytics") == :unknown
    end

    test "follows the cookie, category by category" do
      conn = with_cookie(request(), Consent.encode(consent(), @secret))

      assert Consent.status(conn, "analytics") == :granted
      assert Consent.status(conn, "marketing") == :denied
      assert Consent.status(conn, "no-such-category") == :unknown
    end

    test "necessary is always granted" do
      assert Consent.status(request(), "necessary") == :granted
    end

    test "an unsigned cookie decides nothing" do
      conn = with_cookie(request(), ~s({"analytics":true}))
      assert Consent.status(conn, "analytics") == :unknown
    end

    test "answers :unknown for any other arguments instead of raising" do
      granted = with_cookie(request(), Consent.encode(consent(), @secret))

      for {conn, category} <- [
            {granted, :analytics},
            {granted, nil},
            {granted, 42},
            {granted, ["analytics"]},
            {nil, "analytics"},
            {%{}, "analytics"},
            {"conn", "analytics"},
            {%{cookies: %{}}, :analytics},
            {nil, nil}
          ] do
        assert Consent.status(conn, category) == :unknown,
               "status(#{inspect(conn, limit: 3)}, #{inspect(category)})"
      end
    end
  end

  describe "read/1" do
    test "is :none for anything that is not a request" do
      for other <- [nil, %{}, "conn", :conn, 42, %{cookies: %{"pk_consent" => "x"}}] do
        assert Consent.read(other) == :none
      end
    end
  end

  describe "objected?/1" do
    test "is true only for Sec-GPC: 1" do
      assert Consent.objected?(request([{"sec-gpc", "1"}]))
      refute Consent.objected?(request([{"sec-gpc", "0"}]))
      refute Consent.objected?(request())
    end
  end

  describe "record/3" do
    test "sets a signed cookie carrying the decision" do
      assert {:ok, conn, recorded} =
               Consent.record(request(), %{"analytics" => true}, version: "2.0", source: "banner")

      assert recorded.categories == %{
               "analytics" => true,
               "marketing" => false,
               "preferences" => false
             }

      assert %{value: value, max_age: max_age, same_site: "Lax", http_only: false} =
               conn.resp_cookies["pk_consent"]

      assert max_age == 180 * 86_400
      assert {:ok, ^recorded} = Consent.decode(value, @secret)
      assert recorded.version == "2.0"
    end

    test "only a strict true is a yes, and unknown categories are dropped" do
      {:ok, _conn, recorded} =
        Consent.record(
          request(),
          %{"analytics" => "true", "marketing" => 1, "preferences" => true, "tracking" => true},
          version: "1.0"
        )

      assert recorded.categories == %{
               "analytics" => false,
               "marketing" => false,
               "preferences" => true
             }
    end

    test "a source outside the list is recorded as the banner" do
      {:ok, _conn, recorded} = Consent.record(request(), %{}, version: "1.0", source: "<script>")
      assert recorded.source == "banner"
    end

    test "keeps the visitor's consent ID across decisions" do
      {:ok, _conn, first} = Consent.record(request(), %{"analytics" => true}, version: "1.0")

      conn = with_cookie(request(), Consent.encode(first, @secret))
      {:ok, _conn, second} = Consent.record(conn, %{"analytics" => false}, version: "1.0")

      assert second.id == first.id
      refute second.categories["analytics"]
    end

    test "the same decision again changes nothing" do
      {:ok, _conn, first} = Consent.record(request(), %{"analytics" => true}, version: "1.0")
      conn = with_cookie(request(), Consent.encode(first, @secret))

      assert {:ok, conn, ^first} = Consent.record(conn, %{"analytics" => true}, version: "1.0")
      refute Map.has_key?(conn.resp_cookies, "pk_consent")
    end

    test "the same choices under a new policy version are a new decision" do
      {:ok, _conn, first} = Consent.record(request(), %{"analytics" => true}, version: "1.0")
      conn = with_cookie(request(), Consent.encode(first, @secret))

      assert {:ok, conn, second} = Consent.record(conn, %{"analytics" => true}, version: "2.0")
      assert second.version == "2.0"
      assert Map.has_key?(conn.resp_cookies, "pk_consent")
    end

    test "marks the cookie Secure when the visitor came over https" do
      for {scheme, forwarded, secure?} <- [
            {:http, nil, false},
            {:https, nil, true},
            # TLS ended at a proxy: the endpoint sees http, the visitor used https.
            {:http, "https", true},
            {:http, "http", false},
            {:https, "http", true}
          ] do
        headers = if forwarded, do: [{"x-forwarded-proto", forwarded}], else: []
        conn = %{request(headers) | scheme: scheme}

        {:ok, conn, _} = Consent.record(conn, %{}, version: "1.0")

        assert !!conn.resp_cookies["pk_consent"][:secure] == secure?,
               "scheme #{scheme}, x-forwarded-proto #{inspect(forwarded)}"

        # The cookie is removed with the same attributes it was set with.
        forgotten = Consent.forget(%{request(headers) | scheme: scheme})
        assert !!forgotten.resp_cookies["pk_consent"][:secure] == secure?
      end
    end

    test "a decision made signed out is attributed once the visitor signs in" do
      user_uuid = "018e3c4a-1234-7678-abcd-ef1234567890"

      {:ok, conn, anonymous} = Consent.record(request(), %{"analytics" => true}, version: "1.0")
      refute anonymous.with_user
      cookie = conn.resp_cookies["pk_consent"].value

      # The same decision, now with a user: logged once more, cookie re-issued.
      {:ok, conn, attributed} =
        request()
        |> with_cookie(cookie)
        |> Consent.record(%{"analytics" => true}, version: "1.0", user_uuid: user_uuid)

      assert attributed == %{anonymous | with_user: true}
      attributed_cookie = conn.resp_cookies["pk_consent"].value
      assert {:ok, ^attributed} = Consent.decode(attributed_cookie, @secret)

      # And then never again, signed in or not.
      for opts <- [[user_uuid: user_uuid], []] do
        {:ok, conn, same} =
          request()
          |> with_cookie(attributed_cookie)
          |> Consent.record(%{"analytics" => true}, [version: "1.0"] ++ opts)

        assert same == attributed
        refute Map.has_key?(conn.resp_cookies, "pk_consent")
      end
    end

    test "a decision made signed in is marked as attributed from the start" do
      {:ok, _conn, recorded} =
        Consent.record(request(), %{}, version: "1.0", user_uuid: "018e3c4a-1234-7678-abcd-0")

      assert recorded.with_user
    end

    test "cannot sign without the endpoint's secret" do
      conn = %{request() | secret_key_base: nil}
      assert Consent.record(conn, %{"analytics" => true}, version: "1.0") == {:error, :no_secret}
    end

    test "a failed log write does not cost the visitor their decision" do
      # The log is on and there is no repository behind it.
      PhoenixKit.Cache.put(:settings, "legal_consent_log_enabled", "true")

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Consent.record(request(), %{"analytics" => true}, version: "1.0")
        end)

      assert {:ok, conn, _recorded} = result
      assert Map.has_key?(conn.resp_cookies, "pk_consent")
      assert log =~ "consent decision was not logged"
    end
  end

  describe "forget/2" do
    test "expires the cookie" do
      conn =
        request()
        |> with_cookie(Consent.encode(consent(), @secret))
        |> Consent.forget()

      assert %{max_age: 0} = conn.resp_cookies["pk_consent"]
    end

    test "without a cookie there is nothing to log and the cookie is still expired" do
      # The log is on with no repository behind it: a write would be logged
      # as a failure, so silence shows that none was attempted.
      PhoenixKit.Cache.put(:settings, "legal_consent_log_enabled", "true")

      for conn <- [request(), with_cookie(request(), "not-a-signed-value")] do
        {conn, log} = ExUnit.CaptureLog.with_log(fn -> Consent.forget(conn, source: "api") end)

        assert %{max_age: 0} = conn.resp_cookies["pk_consent"]
        refute log =~ "not logged"
      end
    end
  end

  describe "describe_failure/1" do
    test "names fields and messages, never the values a rejected entry holds" do
      changeset =
        ConsentLog.changeset(%ConsentLog{}, %{
          consent_type: "tracking",
          consent_version: String.duplicate("9", 40),
          ip_address: "203.0.113.7",
          user_uuid: "018e3c4a-1234-7678-abcd-ef1234567890",
          session_id: "visitor-1"
        })

      refute changeset.valid?

      for reason <- [changeset, {:error, changeset}, [{:error, changeset}, {:error, changeset}]] do
        described = Consent.describe_failure(reason)

        assert described =~ "consent_type is invalid"
        assert described =~ "consent_version should be at most"

        for secret <- ["203.0.113.7", "018e3c4a", "visitor-1", "Changeset", "tracking"],
            do: refute(described =~ secret)
      end
    end

    test "an exception is named, its message — which may quote the entry — is not" do
      error = %Ecto.InvalidChangesetError{
        action: :insert,
        changeset: Ecto.Changeset.change(%ConsentLog{}, ip_address: "203.0.113.7")
      }

      assert Consent.describe_failure(error) == "Ecto.InvalidChangesetError"
      assert Consent.describe_failure(:timeout) == ":timeout"
      assert Consent.describe_failure({"203.0.113.7", %{}}) == "unexpected error"
    end
  end

  describe "settings_writes/1" do
    test "a full map is every setting, as the strings the settings table holds" do
      attrs = %{
        log: true,
        log_ip: false,
        log_user_agent: true,
        reload_on_withdrawal: false,
        cookie_days: "90"
      }

      assert Consent.settings_writes(attrs) ==
               {:ok,
                [
                  {"legal_consent_log_enabled", "true"},
                  {"legal_consent_log_ip", "false"},
                  {"legal_consent_log_user_agent", "true"},
                  {"legal_consent_reload_on_withdrawal", "false"},
                  {"legal_consent_cookie_days", "90"}
                ]}
    end

    test "only the keys present are written" do
      for {attrs, expected} <- [
            {%{}, []},
            {%{log_ip: true}, [{"legal_consent_log_ip", "true"}]},
            {%{cookie_days: 30}, [{"legal_consent_cookie_days", "30"}]},
            {%{reload_on_withdrawal: true, log: false},
             [
               {"legal_consent_log_enabled", "false"},
               {"legal_consent_reload_on_withdrawal", "true"}
             ]},
            # Only a strict true switches a setting on.
            {%{log: "true", log_user_agent: nil},
             [{"legal_consent_log_enabled", "false"}, {"legal_consent_log_user_agent", "false"}]},
            # String keys are not this function's: nothing is taken from them.
            {%{"log" => true, "cookie_days" => "abc"}, []}
          ] do
        assert Consent.settings_writes(attrs) == {:ok, expected}, inspect(attrs)
      end
    end

    test "days must be a whole number from 1 to 730" do
      for days <- [1, 90, 730, "1", "90", "730"] do
        assert {:ok, [{"legal_consent_cookie_days", stored}]} =
                 Consent.settings_writes(%{cookie_days: days})

        assert stored == to_string(days)
      end

      for days <- [nil, "abc", "0", 0, 731, "731", 3.5, "3.5", " 90 ", "", -1, "90 days", true] do
        assert Consent.settings_writes(%{log: true, cookie_days: days}) ==
                 {:error, :invalid_days},
               inspect(days)
      end
    end
  end

  describe "update_settings/2" do
    setup do
      SettingsRecorder.install()
    end

    test "writes each setting present, for the legal module, with who made the change" do
      opts = [actor_uuid: "018e3c4a-1234-7678-abcd-ef1234567890", source: "settings"]

      assert Consent.update_settings(%{log_ip: true, cookie_days: "365"}, opts) == :ok

      assert SettingsRecorder.written() == [
               %{
                 kind: :string,
                 key: "legal_consent_log_ip",
                 value: "true",
                 module: "legal",
                 opts: opts
               },
               %{
                 kind: :string,
                 key: "legal_consent_cookie_days",
                 value: "365",
                 module: "legal",
                 opts: opts
               }
             ]
    end

    test "a missing key leaves its setting untouched" do
      assert Consent.update_settings(%{}) == :ok
      assert SettingsRecorder.written() == []

      assert Consent.update_settings(%{reload_on_withdrawal: false}) == :ok
      assert [%{key: "legal_consent_reload_on_withdrawal", opts: []}] = SettingsRecorder.written()
    end

    test "an invalid number of days writes nothing at all" do
      for days <- [nil, "abc", "0", 0, 731, 3.5, " 90 "] do
        attrs = %{
          log: true,
          log_ip: true,
          log_user_agent: true,
          reload_on_withdrawal: true,
          cookie_days: days
        }

        assert Consent.update_settings(attrs, source: "settings") == {:error, :invalid_days}
        assert SettingsRecorder.written() == [], inspect(days)
      end
    end
  end

  describe "cookie_days/0" do
    test "falls back to the default for anything unusable, and is capped" do
      for {stored, expected} <- [
            {"abc", 180},
            {"0", 180},
            {"-3", 180},
            {"90", 90},
            {"99999", 730},
            {" 90 ", 90},
            {"730", 730},
            {"731", 730},
            {90, 90},
            {730, 730},
            {731, 730},
            {0, 180},
            {nil, 180},
            {"", 180},
            {"3.5", 180}
          ] do
        PhoenixKit.Cache.put(:settings, "legal_consent_cookie_days", stored)
        assert Consent.cookie_days() == expected
      end
    end
  end
end
