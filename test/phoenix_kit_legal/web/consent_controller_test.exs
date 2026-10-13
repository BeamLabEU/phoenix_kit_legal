defmodule PhoenixKit.Modules.Legal.Web.ConsentControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.Modules.Legal.Consent
  alias PhoenixKit.Modules.Legal.Web.ConsentController

  @secret String.duplicate("s", 64)

  setup do
    for {key, value} <- [
          {"legal_enabled", "true"},
          {"legal_consent_widget_enabled", "true"},
          {"legal_consent_log_enabled", "false"},
          {"legal_consent_log_ip", "false"},
          {"legal_consent_log_user_agent", "false"},
          {"legal_consent_cookie_days", "180"},
          # The manual version: no legal page exists to derive one from.
          {"legal_policy_version", "1.0"}
        ],
        do: PhoenixKit.Cache.put(:settings, key, value)

    :ok
  end

  defp call(method, action, params \\ %{}, headers \\ []) do
    conn = %{conn(method, "/phoenix_kit/api/consent", params) | secret_key_base: @secret}

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    |> ConsentController.call(ConsentController.init(action))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST" do
    test "records the decision and answers with it" do
      conn = call(:post, :record, %{"consent" => %{"analytics" => true}, "source" => "banner"})

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{
               "decided" => true,
               "consent" => %{
                 "necessary" => true,
                 "analytics" => true,
                 "marketing" => false,
                 "preferences" => false
               },
               "version" => "1.0"
             } = body(conn)

      assert {:ok, %Consent{source: "banner"}} =
               Consent.decode(conn.resp_cookies["pk_consent"].value, @secret)
    end

    test "is refused from another site" do
      conn =
        call(:post, :record, %{"consent" => %{"analytics" => true}}, [
          {"origin", "https://evil.example"}
        ])

      assert conn.status == 403
      refute Map.has_key?(conn.resp_cookies, "pk_consent")
    end

    test "is refused when the browser says the request is cross-site" do
      conn =
        call(:post, :record, %{"consent" => %{"analytics" => true}}, [
          {"sec-fetch-site", "cross-site"}
        ])

      assert conn.status == 403
    end

    test "is accepted from the site itself" do
      conn =
        call(:post, :record, %{"consent" => %{"analytics" => true}}, [
          {"origin", "http://www.example.com"}
        ])

      assert conn.status == 200
    end

    test "needs a consent map" do
      for params <- [%{}, %{"consent" => "yes"}, %{"consent" => ["analytics"]}] do
        conn = call(:post, :record, params)
        assert conn.status == 422
        refute Map.has_key?(conn.resp_cookies, "pk_consent")
      end
    end

    test "answers 404 and sets nothing while the banner is off" do
      PhoenixKit.Cache.put(:settings, "legal_consent_widget_enabled", "false")
      conn = call(:post, :record, %{"consent" => %{"analytics" => true}})

      assert conn.status == 404
      refute Map.has_key?(conn.resp_cookies, "pk_consent")
    end

    test "answers 404 while the module is off" do
      PhoenixKit.Cache.put(:settings, "legal_enabled", "false")
      assert call(:post, :record, %{"consent" => %{"analytics" => true}}).status == 404
    end
  end

  describe "GET" do
    test "says nothing was decided without a cookie, and reports Global Privacy Control" do
      assert body(call(:get, :show)) == %{"decided" => false, "gpc" => false}

      assert body(call(:get, :show, %{}, [{"sec-gpc", "1"}])) == %{
               "decided" => false,
               "gpc" => true
             }
    end

    test "returns the decision the cookie holds" do
      recorded = call(:post, :record, %{"consent" => %{"marketing" => true}})
      cookie = recorded.resp_cookies["pk_consent"].value

      conn = call(:get, :show, %{}, [{"cookie", "pk_consent=#{cookie}"}])

      assert %{"decided" => true, "consent" => %{"marketing" => true, "analytics" => false}} =
               body(conn)
    end
  end

  describe "DELETE" do
    test "removes the cookie" do
      recorded = call(:post, :record, %{"consent" => %{"analytics" => true}})
      cookie = recorded.resp_cookies["pk_consent"].value

      conn = call(:delete, :forget, %{}, [{"cookie", "pk_consent=#{cookie}"}])

      assert conn.status == 200
      assert %{max_age: 0} = conn.resp_cookies["pk_consent"]
      assert body(conn)["decided"] == false
    end

    test "is refused from another site" do
      conn = call(:delete, :forget, %{}, [{"origin", "https://evil.example"}])
      assert conn.status == 403
    end
  end
end
