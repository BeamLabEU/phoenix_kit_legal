defmodule PhoenixKit.Modules.Legal.Web.ConsentController do
  @moduledoc """
  The endpoint the banner reports a visitor's decision to.

    * `GET /api/consent` — the decision the server holds for this browser
    * `POST /api/consent` — record a decision (`{"consent": {"analytics": true, …}}`)
    * `DELETE /api/consent` — forget it, so the visitor is asked again

  All three are public: a visitor decides before they are anyone. What keeps
  the write honest is in this module rather than in a session:

    * **Same site only.** A browser sends `Origin` on every cross-origin
      `POST`/`DELETE`; one that names another host is refused, so a third-party
      page cannot record a "yes" in a visitor's name.
    * **Nothing is taken from the body but booleans** for the known
      categories and a source from a fixed list. The policy version, the
      consent ID and the time are the server's.
    * **A repeated decision writes nothing**, and each address is held to a
      few writes a minute, so the log cannot be filled by replaying a request.

  The answer is the same whether or not the module is switched on, apart from
  the status: an endpoint that is off answers 404 and sets no cookie.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.Consent
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

  # `Origin` when the browser sends it (always, on a cross-origin write),
  # else `Sec-Fetch-Site`. A request carrying neither is not from a browser
  # page at all — a script or a server — and has no visitor's cookie to abuse.
  defp require_same_site(conn, _opts) do
    if same_site?(conn) do
      conn
    else
      conn |> put_status(:forbidden) |> json(%{error: "cross-site request"}) |> halt()
    end
  end

  defp same_site?(conn) do
    case {get_req_header(conn, "origin"), get_req_header(conn, "sec-fetch-site")} do
      {[origin | _], _} -> origin_host(origin) == conn.host
      {[], [site | _]} -> site in ["same-origin", "none"]
      {[], []} -> true
    end
  end

  defp origin_host(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp rate_limit(conn, _opts) do
    key = "legal_consent:" <> (IpAddress.client_address(conn) || "unknown")

    case RateLimiter.hit(key, :timer.minutes(1), @writes_per_minute) do
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
