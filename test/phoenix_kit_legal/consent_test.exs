defmodule PhoenixKit.Modules.Legal.ConsentTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.Modules.Legal.Consent

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

      forged =
        Base.url_encode64(
          Jason.encode!(%{"id" => "x", "v" => "1.0", "c" => %{"analytics" => true}, "t" => 1}),
          padding: false
        )

      assert Consent.decode(Enum.join([head, forged, signature], "."), @secret) == :none
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

    test "marks the cookie Secure on https only" do
      {:ok, plain, _} = Consent.record(request(), %{}, version: "1.0")
      {:ok, secure, _} = Consent.record(%{request() | scheme: :https}, %{}, version: "1.0")

      refute plain.resp_cookies["pk_consent"][:secure]
      assert secure.resp_cookies["pk_consent"][:secure]
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
  end

  describe "cookie_days/0" do
    test "falls back to the default for anything unusable, and is capped" do
      for {stored, expected} <- [
            {"abc", 180},
            {"0", 180},
            {"-3", 180},
            {"90", 90},
            {"99999", 730}
          ] do
        PhoenixKit.Cache.put(:settings, "legal_consent_cookie_days", stored)
        assert Consent.cookie_days() == expected
      end
    end
  end
end
