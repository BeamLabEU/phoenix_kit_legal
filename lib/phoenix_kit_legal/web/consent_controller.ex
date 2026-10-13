defmodule PhoenixKit.Modules.Legal.Web.ConsentController do
  @moduledoc """
  The endpoint the banner reports a visitor's decision to.

    * `GET /api/consent` — the decision the server holds for this browser
    * `POST /api/consent` — record a decision (`{"consent": {"analytics": true, …}}`)
    * `DELETE /api/consent` — forget it, so the visitor is asked again

  All three are public: a visitor decides before they are anyone. What keeps
  the write honest is in this module rather than in a session:

    * **Same origin only.** A browser sends `Origin` on every cross-origin
      `POST`/`DELETE`; one that names another host — or the same host on
      another port, which shares the cookie but is another origin — is
      refused, so a third-party page cannot record a "yes" in a visitor's
      name. What counts as this site is the request's `Host`, the
      `x-forwarded-host` a proxy set, or the configured `site_url`.
    * **Nothing is taken from the body but booleans** for the known
      categories and a source from a fixed list. The policy version, the
      consent ID and the time are the server's.
    * **A repeated decision writes nothing**, and each address (each /64,
      for IPv6) is held to a few writes a minute, so the log cannot be filled
      by replaying a request.

  The answer is the same whether or not the module is switched on, apart from
  the status: an endpoint that is off answers 404 and sets no cookie.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Consent
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RateLimiter.Backend, as: RateLimiter
  alias PhoenixKit.Utils.IpAddress

  @writes_per_minute 20

  plug :no_store
  plug :require_enabled
  plug :require_same_site when action in [:record, :forget]
  plug :rate_limit when action in [:record, :forget]

  @doc "The decision the server holds for this browser."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Consent.read(conn) do
      {:ok, consent} -> json(conn, body(conn, consent))
      :none -> json(conn, %{decided: false, gpc: Consent.objected?(conn)})
    end
  end

  @doc "Records a decision and sets the consent cookie."
  @spec record(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def record(conn, %{"consent" => categories} = params) when is_map(categories) do
    opts = [source: params["source"], user_uuid: current_user_uuid(conn)]

    case Consent.record(conn, categories, opts) do
      {:ok, conn, consent} ->
        json(conn, body(conn, consent))

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{decided: false})
    end
  end

  def record(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "consent is required"})
  end

  @doc "Forgets the decision: logs every category as refused and removes the cookie."
  @spec forget(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def forget(conn, _params) do
    conn
    |> Consent.forget(source: "preferences", user_uuid: current_user_uuid(conn))
    |> json(%{decided: false, gpc: Consent.objected?(conn)})
  end

  defp body(conn, consent) do
    %{
      decided: true,
      id: consent.id,
      version: consent.version,
      consent: Map.put(consent.categories, "necessary", true),
      decided_at: consent.decided_at,
      gpc: Consent.objected?(conn)
    }
  end

  # ── plugs ─────────────────────────────────────────────────────────────────

  # The answer is one visitor's; no cache may hand it to another.
  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp require_enabled(conn, _opts) do
    if Legal.enabled?() and Legal.consent_widget_enabled?() do
      conn
    else
      conn |> send_resp(:not_found, "") |> halt()
    end
  end

  # `Origin` when the browser sends one that names an origin, else
  # `Sec-Fetch-Site`. A request carrying neither is not from a browser page
  # at all — a script or a server — and has no visitor's cookie to abuse.
  defp require_same_site(conn, _opts) do
    if same_site?(conn) do
      conn
    else
      conn |> put_status(:forbidden) |> json(%{error: "cross-site request"}) |> halt()
    end
  end

  # `Origin: null` is not a refusal: a browser sends it on a same-origin
  # write too, when the page's `Referrer-Policy` is `no-referrer`. It only
  # says the header has nothing to tell, so the browser's own verdict in
  # `Sec-Fetch-Site` decides, as it does when there is no `Origin` at all.
  defp same_site?(conn) do
    case origin(conn) do
      {scheme, authority} -> authority in own_authorities(conn, scheme)
      nil -> fetch_site_allows?(conn)
    end
  end

  defp fetch_site_allows?(conn) do
    case get_req_header(conn, "sec-fetch-site") do
      [site | _] -> site in ["same-origin", "none"]
      [] -> true
    end
  end

  defp origin(conn) do
    with [value | _] <- get_req_header(conn, "origin"),
         %URI{scheme: scheme, host: host, port: port}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.parse(value) do
      {scheme, authority(host, port)}
    else
      _ -> nil
    end
  end

  # Every name this site answers to, as `{host, port}`. Host and port, not the
  # host alone: cookies ignore the port, so a page on another port of the
  # same host would otherwise write with the visitor's cookie.
  #
  #   * the `Host` header — not `conn.port`, which behind a proxy can be the
  #     port the app listens on rather than the one the visitor used;
  #   * `x-forwarded-host`, which a proxy sets and a cross-site page cannot
  #     (a browser's `fetch` may not send it across origins without a
  #     preflight this endpoint does not answer);
  #   * the operator's `site_url`.
  #
  # A header carries no scheme, so a missing port is the default of the
  # scheme the `Origin` came with.
  defp own_authorities(conn, scheme) do
    host =
      case get_req_header(conn, "host") do
        [value | _] -> header_authority(value, scheme)
        # HTTP/2 has no `Host` header; the adapter read the authority.
        [] -> authority(conn.host, conn.port)
      end

    forwarded =
      conn
      |> get_req_header("x-forwarded-host")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&header_authority(String.trim(&1), scheme))

    Enum.reject([host, site_url_authority() | forwarded], &is_nil/1)
  end

  defp header_authority(value, scheme) do
    case URI.parse(scheme <> "://" <> value) do
      %URI{host: host, port: port} when is_binary(host) and host != "" -> authority(host, port)
      _ -> nil
    end
  end

  defp site_url_authority do
    with url when is_binary(url) and url != "" <- Settings.get_setting_cached("site_url", nil),
         %URI{host: host, port: port} when is_binary(host) and host != "" <- URI.parse(url) do
      authority(host, port)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # `URI.parse/1` fills in the scheme's default port, so `https://a` and
  # `https://a:443` are the same authority here.
  defp authority(host, port), do: {String.downcase(host), port}

  defp rate_limit(conn, _opts) do
    case RateLimiter.hit(rate_limit_key(conn), :timer.minutes(1), @writes_per_minute) do
      {:deny, _retry_ms} ->
        conn |> put_status(:too_many_requests) |> json(%{error: "too many requests"}) |> halt()

      _ ->
        conn
    end
  rescue
    # The limiter is core's and may not be running (a host that never started
    # it, a test); a decision is still to be recorded.
    _ -> conn
  catch
    :exit, _ -> conn
  end

  # One bucket per network, not per address: an IPv6 client is handed a whole
  # /64 and can use a new address for every request. Core gained `network/1`
  # in 2.27; before that the address is all there is.
  defp rate_limit_key(conn) do
    address = IpAddress.client_address(conn) || "unknown"

    network =
      if function_exported?(IpAddress, :network, 1),
        do: IpAddress.network(address),
        else: address

    "legal_consent:" <> network
  end

  # The route carries no auth pipeline — a visitor decides before signing in —
  # so the signed-in user, when there is one, is read from the session here.
  defp current_user_uuid(conn) do
    conn = fetch_session(conn)

    with token when is_binary(token) <- get_session(conn, :user_token),
         %{uuid: uuid} <- Auth.get_user_by_session_token(token) do
      uuid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
