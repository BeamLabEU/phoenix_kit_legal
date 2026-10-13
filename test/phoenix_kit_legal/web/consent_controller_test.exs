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
          {"legal_policy_version", "1.0"},
          {"site_url", ""}
        ],
        do: PhoenixKit.Cache.put(:settings, key, value)

    :ok
  end

  # `Plug.Test` sets `conn.host` but sends no `Host` header, and
  # `put_req_header/3` refuses to add one; a real request always has it (or
  # an HTTP/2 authority). So the helper puts the header where the web server
  # would, unless the test brings its own.
  defp call(method, action, params \\ %{}, headers \\ [], conn_fields \\ %{}) do
    conn =
      conn(method, "/phoenix_kit/api/consent", params)
      |> Map.put(:secret_key_base, @secret)
      |> Map.merge(conn_fields)

    headers = Enum.uniq_by(headers ++ [{"host", "www.example.com"}], &elem(&1, 0))

    ConsentController.call(
      %{conn | req_headers: headers ++ conn.req_headers},
      ConsentController.init(action)
    )
  end

  @decision %{"consent" => %{"analytics" => true}}

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

  describe "the same-site rule" do
    # What `Origin` says, when it names an origin, decides alone.
    @origins [
      {"no Origin", nil, :fetch_site},
      {"Origin: null", "null", :fetch_site},
      {"an unparsable Origin", "%%%not a url", :fetch_site},
      {"an Origin with no host", "https://", :fetch_site},
      {"the same host", "http://www.example.com", :allowed},
      {"the same host, default port spelled out", "http://www.example.com:80", :allowed},
      {"the same host, another port", "http://www.example.com:4444", :refused},
      {"another host", "https://evil.example", :refused},
      {"a sibling subdomain", "http://api.example.com", :refused},
      {"a parent domain", "http://example.com", :refused}
    ]

    # Without one, the browser's own verdict does.
    @fetch_sites [
      {nil, :allowed},
      {"same-origin", :allowed},
      {"none", :allowed},
      {"same-site", :refused},
      {"cross-site", :refused}
    ]

    for {label, origin, by_origin} <- @origins, {fetch_site, by_fetch_site} <- @fetch_sites do
      expected = if by_origin == :fetch_site, do: by_fetch_site, else: by_origin

      test "#{label}, Sec-Fetch-Site #{inspect(fetch_site)}: #{expected}" do
        headers =
          Enum.reject(
            [{"origin", unquote(origin)}, {"sec-fetch-site", unquote(fetch_site)}],
            fn {_name, value} -> is_nil(value) end
          )

        for {method, action} <- [{:post, :record}, {:delete, :forget}] do
          conn = call(method, action, @decision, headers)

          case unquote(expected) do
            :allowed ->
              assert conn.status == 200

            :refused ->
              assert conn.status == 403
              assert body(conn) == %{"error" => "cross-site request"}
              refute Map.has_key?(conn.resp_cookies, "pk_consent")
          end
        end
      end
    end

    test "host and port are compared against the Host header, default ports dropped" do
      for {origin, host, status} <- [
            # Development: the port is part of both.
            {"http://localhost:4010", "localhost:4010", 200},
            {"http://localhost:4011", "localhost:4010", 403},
            {"http://localhost", "localhost:4010", 403},
            # TLS ended at a proxy: https outside, a bare Host inside.
            {"https://app.example", "app.example", 200},
            {"https://app.example", "app.example:443", 200},
            {"https://app.example:443", "app.example", 200},
            # Cookies ignore the port; an origin does not.
            {"https://app.example:4444", "app.example", 403},
            {"https://app.example", "app.example:4444", 403},
            {"https://APP.example", "app.EXAMPLE", 200},
            {"http://[::1]:4000", "[::1]:4000", 200},
            {"http://[::1]:4001", "[::1]:4000", 403}
          ] do
        conn = call(:post, :record, @decision, [{"host", host}, {"origin", origin}])
        assert conn.status == status, "Origin #{origin}, Host #{host}"
      end
    end

    test "conn.port is not consulted when there is a Host header" do
      # Behind a proxy the endpoint listens on its own port.
      conn =
        call(
          :post,
          :record,
          @decision,
          [{"host", "app.example"}, {"origin", "https://app.example"}],
          %{port: 4000}
        )

      assert conn.status == 200
    end

    test "without a Host header (HTTP/2) the adapter's authority is used" do
      request = %{conn(:post, "/phoenix_kit/api/consent", @decision) | secret_key_base: @secret}

      send_from = fn fields ->
        request
        |> Map.merge(fields)
        |> put_req_header("origin", "http://app.example:4000")
        |> ConsentController.call(ConsentController.init(:record))
      end

      assert send_from.(%{host: "app.example", port: 4000}).status == 200
      assert send_from.(%{host: "app.example", port: 80}).status == 403
    end

    test "the host a proxy forwarded is this site too" do
      for {origin, forwarded, status} <- [
            {"https://shop.example", "shop.example", 200},
            {"https://shop.example", "other.example, shop.example", 200},
            {"https://shop.example:8443", "shop.example:8443", 200},
            {"https://shop.example:8443", "shop.example", 403},
            {"https://evil.example", "shop.example", 403},
            {"https://shop.example", "", 403}
          ] do
        conn =
          call(:post, :record, @decision, [
            {"host", "10.0.0.5:4000"},
            {"origin", origin},
            {"x-forwarded-host", forwarded}
          ])

        assert conn.status == status, "Origin #{origin}, X-Forwarded-Host #{inspect(forwarded)}"
      end
    end

    test "so is the configured site_url" do
      for {site_url, origin, status} <- [
            {"https://shop.example", "https://shop.example", 200},
            {"https://shop.example/", "https://shop.example:443", 200},
            {"https://shop.example:8443/path", "https://shop.example:8443", 200},
            {"https://shop.example", "https://shop.example:8443", 403},
            {"https://shop.example", "https://evil.example", 403},
            {"https://shop.example", "https://www.shop.example", 403},
            # Another scheme is another origin.
            {"https://shop.example", "http://shop.example", 403},
            {"", "https://shop.example", 403},
            {"not a url", "https://shop.example", 403},
            {nil, "https://shop.example", 403}
          ] do
        PhoenixKit.Cache.put(:settings, "site_url", site_url)

        conn =
          call(:post, :record, @decision, [{"host", "10.0.0.5:4000"}, {"origin", origin}])

        assert conn.status == status, "site_url #{inspect(site_url)}, Origin #{origin}"
      end
    end
  end

  describe "a refused origin" do
    @refused_key {ConsentController, :refused_origins}

    setup do
      # The suite logs from :warning up; this is logged at :info.
      previous = Logger.level()
      Logger.configure(level: :info)
      :persistent_term.erase(@refused_key)

      on_exit(fn ->
        Logger.configure(level: previous)
        :persistent_term.erase(@refused_key)
      end)
    end

    defp refuse(origin, headers \\ []) do
      ExUnit.CaptureLog.with_log([level: :info], fn ->
        conn =
          call(
            :post,
            :record,
            @decision,
            [{"origin", origin}, {"user-agent", "Mozilla/5.0 Visitor"} | headers],
            %{remote_ip: {203, 0, 113, 99}}
          )

        assert conn.status == 403
      end)
      |> elem(1)
    end

    test "is logged with what it was compared against, and nothing of the visitor" do
      PhoenixKit.Cache.put(:settings, "site_url", "https://shop.example")

      log =
        refuse("https://www.shop.example", [
          {"host", "10.0.0.5:4000"},
          {"x-forwarded-host", "edge.example"},
          {"cookie", "pk_consent=secret-cookie"}
        ])

      assert log =~ "[info]"
      assert log =~ "consent write refused as cross-site"
      assert log =~ ~s(Origin "www.shop.example:443")
      # The three names this site answers to, as the request gave them.
      assert log =~ ~s("10.0.0.5:4000")
      assert log =~ ~s("shop.example:443")
      assert log =~ ~s("edge.example:443")

      for held <- ["203.0.113.99", "Mozilla", "secret-cookie", "analytics"],
          do: refute(log =~ held)
    end

    test "is logged once, however often it comes back" do
      assert refuse("https://evil.example") =~ ~s(Origin "evil.example:443")
      assert refuse("https://evil.example") == ""
      # The same authority spelled another way.
      assert refuse("https://EVIL.example:443") == ""
      # Another port is another origin.
      assert refuse("https://evil.example:8443") =~ ~s("evil.example:8443")
    end

    test "an accepted write, and one refused by Sec-Fetch-Site alone, log nothing" do
      {_, log} =
        ExUnit.CaptureLog.with_log([level: :info], fn ->
          assert call(:post, :record, @decision, [{"origin", "http://www.example.com"}]).status ==
                   200

          assert call(:post, :record, @decision, [{"sec-fetch-site", "cross-site"}]).status == 403
        end)

      refute log =~ "refused"
      assert :persistent_term.get(@refused_key, MapSet.new()) == MapSet.new()
    end

    test "only the first fifty origins are remembered or logged" do
      logs = for n <- 1..60, do: refuse("https://attacker-#{n}.example")

      assert Enum.count(logs, &(&1 != "")) == 50
      assert MapSet.size(:persistent_term.get(@refused_key)) == 50
      assert Enum.at(logs, 49) =~ "attacker-50.example"
      assert Enum.at(logs, 50) == ""

      # One already remembered stays quiet; a new one no longer gets in.
      assert refuse("https://attacker-1.example") == ""
      assert refuse("https://one-more.example") == ""
      assert MapSet.size(:persistent_term.get(@refused_key)) == 50
    end

    test "a host too long to be a host name is refused without being remembered" do
      long = String.duplicate("a", 300) <> ".example"

      assert refuse("https://" <> long) == ""
      assert :persistent_term.get(@refused_key, MapSet.new()) == MapSet.new()
    end
  end

  describe "without the endpoint's secret" do
    test "a decision cannot be signed: 503, and no cookie" do
      conn = call(:post, :record, @decision, [], %{secret_key_base: nil})

      assert conn.status == 503
      assert body(conn) == %{"decided" => false}
      refute Map.has_key?(conn.resp_cookies, "pk_consent")
    end
  end

  describe "the rate limit" do
    setup do
      # Core's limiter, started the way core's supervisor starts it.
      start_supervised!(PhoenixKit.Users.RateLimiter.Backend)
      :ok
    end

    defp from(address, method, action, params) do
      call(method, action, params, [], %{remote_ip: address})
    end

    test "the 21st write in a minute from one address is refused, and sets nothing" do
      address = {203, 0, 113, 21}

      for n <- 1..20 do
        # A different decision each time, so each is a real write.
        conn = from(address, :post, :record, %{"consent" => %{"analytics" => rem(n, 2) == 0}})
        assert conn.status == 200, "write #{n}"
      end

      conn = from(address, :post, :record, @decision)

      assert conn.status == 429
      assert body(conn) == %{"error" => "too many requests"}
      refute Map.has_key?(conn.resp_cookies, "pk_consent")

      # Another visitor is not held back by this one.
      assert from({203, 0, 113, 22}, :post, :record, @decision).status == 200
    end

    test "DELETE counts against the same limit" do
      address = {203, 0, 113, 23}

      for _ <- 1..10, do: assert(from(address, :post, :record, @decision).status == 200)
      for _ <- 1..10, do: assert(from(address, :delete, :forget, %{}).status == 200)

      refused = from(address, :delete, :forget, %{})
      assert refused.status == 429
      refute Map.has_key?(refused.resp_cookies, "pk_consent")

      assert from(address, :post, :record, @decision).status == 429
    end

    test "reads are not limited" do
      address = {203, 0, 113, 24}
      for _ <- 1..25, do: assert(from(address, :get, :show, %{}).status == 200)
    end

    test "an IPv6 client rotating inside its /64 shares one bucket" do
      # Core gained `IpAddress.network/1` in 2.27; on an older core the pin
      # still admits, each address is its own bucket and this cannot hold.
      if function_exported?(PhoenixKit.Utils.IpAddress, :network, 1) do
        for n <- 1..20 do
          address = {0x2A0D, 0x3344, 0x6A, 0xC310, 0, 0, 0, n}
          assert from(address, :post, :record, @decision).status == 200
        end

        same_network = {0x2A0D, 0x3344, 0x6A, 0xC310, 0xFFFF, 0, 0, 1}
        assert from(same_network, :post, :record, @decision).status == 429

        other_network = {0x2A0D, 0x3344, 0x6A, 0xC311, 0, 0, 0, 1}
        assert from(other_network, :post, :record, @decision).status == 200
      end
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
