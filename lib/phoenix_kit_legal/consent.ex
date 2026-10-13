defmodule PhoenixKit.Modules.Legal.Consent do
  @moduledoc """
  A visitor's consent decision, as the server knows it.

  The banner keeps the decision in the browser's `localStorage`, which no
  server can read. This module is the server's copy: a first-party cookie the
  consent endpoint sets when the visitor decides, and the audit row written at
  the same moment. Anything that collects data on the server asks here before
  it does.

  ## Asking

      case PhoenixKit.Modules.Legal.Consent.status(conn, "analytics") do
        :granted -> ...   # the visitor said yes
        :denied -> ...    # the visitor said no
        :unknown -> ...   # the visitor has not decided (or the cookie expired)
      end

      PhoenixKit.Modules.Legal.Consent.objected?(conn)
      # true when the browser sends Global Privacy Control

  Both read the request only — a cookie and a header — and never query the
  database, so they are safe on a hot path.

  ## The cookie

  `pk_consent`, set by the server, readable by JavaScript, `SameSite=Lax`.
  Its value is the decision as JSON, signed with a key derived from the
  endpoint's `secret_key_base` (`Plug.Crypto.MessageVerifier`), so a visitor
  can read their decision but a script cannot forge one the server will
  believe. An unsigned, tampered or expired cookie reads as no decision.

  It carries no identity: a random consent ID, the policy version, the
  categories, when and where the decision was made.

  ## The record

  `record/3` writes one `phoenix_kit_consent_logs` row per category, keyed by
  the consent ID (and the user's UUID when signed in). The visitor's address
  and a hash of their User-Agent are added only when
  `legal_consent_log_ip` / `legal_consent_log_user_agent` ask for them; both
  are off by default. A decision identical to the one the visitor's cookie
  already holds is not written twice.
  """

  import Plug.Conn

  require Logger

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Legal.ConsentLog
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.IpAddress
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageVerifier

  @cookie "pk_consent"
  @key_salt "phoenix_kit_legal consent cookie"
  @categories ~w(analytics marketing preferences)
  @sources ~w(banner preferences sync api)
  @default_days 180
  @max_days 730

  @log_key "legal_consent_log_enabled"
  @log_ip_key "legal_consent_log_ip"
  @log_user_agent_key "legal_consent_log_user_agent"
  @days_key "legal_consent_cookie_days"
  @reload_key "legal_consent_reload_on_withdrawal"

  @enforce_keys [:id, :version, :categories, :source, :decided_at]
  defstruct [:id, :version, :categories, :source, :decided_at]

  @type status :: :granted | :denied | :unknown
  @type t :: %__MODULE__{
          id: String.t(),
          version: String.t(),
          categories: %{String.t() => boolean()},
          source: String.t(),
          decided_at: integer()
        }

  @doc "The cookie's name."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie

  @doc "The categories a visitor decides on. `necessary` is not one: it is never asked."
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @doc "Where a decision can come from."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  # ── settings ──────────────────────────────────────────────────────────────

  @doc "Whether decisions are written to the consent log (on by default)."
  @spec log_enabled?() :: boolean()
  def log_enabled?, do: Settings.get_boolean_setting(@log_key, true)

  @doc "Whether a log entry keeps the visitor's address (off by default)."
  @spec log_ip?() :: boolean()
  def log_ip?, do: Settings.get_boolean_setting(@log_ip_key, false)

  @doc "Whether a log entry keeps a hash of the User-Agent (off by default)."
  @spec log_user_agent?() :: boolean()
  def log_user_agent?, do: Settings.get_boolean_setting(@log_user_agent_key, false)

  @doc "Whether the page reloads when a visitor takes a consent back (on by default)."
  @spec reload_on_withdrawal?() :: boolean()
  def reload_on_withdrawal?, do: Settings.get_boolean_setting(@reload_key, true)

  @doc "Days a decision lasts before the visitor is asked again."
  @spec cookie_days() :: pos_integer()
  def cookie_days do
    case Settings.get_setting_cached(@days_key, nil) do
      value when is_binary(value) -> parse_days(value)
      value when is_integer(value) -> clamp_days(value)
      _ -> @default_days
    end
  end

  @doc "The default and the longest lifetime of a decision, in days."
  @spec day_bounds() :: %{default: pos_integer(), max: pos_integer()}
  def day_bounds, do: %{default: @default_days, max: @max_days}

  @doc """
  Saves the settings of the record: `:log`, `:log_ip`, `:log_user_agent`,
  `:reload_on_withdrawal` (booleans) and `:cookie_days`.
  """
  @spec update_settings(map()) :: :ok | {:error, term()}
  def update_settings(attrs) when is_map(attrs) do
    writes = [
      {@log_key, to_string(attrs[:log] == true)},
      {@log_ip_key, to_string(attrs[:log_ip] == true)},
      {@log_user_agent_key, to_string(attrs[:log_user_agent] == true)},
      {@reload_key, to_string(attrs[:reload_on_withdrawal] == true)},
      {@days_key, attrs[:cookie_days] |> to_string() |> parse_days() |> to_string()}
    ]

    Enum.reduce_while(writes, :ok, fn {key, value}, :ok ->
      case Settings.update_setting_with_module(key, value, Legal.module_key()) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_days(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} -> clamp_days(days)
      _ -> @default_days
    end
  end

  defp clamp_days(days) when days >= 1, do: min(days, @max_days)
  defp clamp_days(_days), do: @default_days

  # ── reading ───────────────────────────────────────────────────────────────

  @doc """
  The decision the request carries, or `:none`.

  `:none` covers every way there can be no decision the server will act on:
  no cookie, a value that was not signed by this site, one that has expired,
  or an endpoint without a `secret_key_base`.
  """
  @spec read(Plug.Conn.t()) :: {:ok, t()} | :none
  def read(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn)
    decode(conn.cookies[@cookie], conn.secret_key_base)
  end

  @doc """
  What the visitor decided about one category.

  `necessary` is always `:granted`; an unknown category is `:unknown`.
  """
  @spec status(Plug.Conn.t(), String.t()) :: status()
  def status(_conn, "necessary"), do: :granted

  def status(%Plug.Conn{} = conn, category) when is_binary(category) do
    case read(conn) do
      {:ok, %__MODULE__{categories: %{^category => true}}} -> :granted
      {:ok, %__MODULE__{categories: %{^category => false}}} -> :denied
      _ -> :unknown
    end
  end

  @doc """
  Whether the browser itself objects, by sending Global Privacy Control
  (`Sec-GPC: 1`). An objection needs no cookie: it is there on the first
  request.
  """
  @spec objected?(Plug.Conn.t()) :: boolean()
  def objected?(%Plug.Conn{} = conn), do: get_req_header(conn, "sec-gpc") == ["1"]

  @doc """
  Turns a cookie value back into a decision — `:none` unless it was signed
  with this `secret_key_base`, is well-formed and has not expired.
  """
  @spec decode(term(), term()) :: {:ok, t()} | :none
  def decode(value, secret_key_base)
      when is_binary(value) and value != "" and is_binary(secret_key_base) do
    with {:ok, json} <- MessageVerifier.verify(value, signing_key(secret_key_base)),
         {:ok, payload} <- Jason.decode(json),
         {:ok, consent} <- from_payload(payload),
         true <- fresh?(consent) do
      {:ok, consent}
    else
      _ -> :none
    end
  end

  def decode(_value, _secret_key_base), do: :none

  @doc "The signed cookie value for a decision."
  @spec encode(t(), String.t()) :: String.t()
  def encode(%__MODULE__{} = consent, secret_key_base) when is_binary(secret_key_base) do
    payload = %{
      "id" => consent.id,
      "v" => consent.version,
      "c" => consent.categories,
      "s" => consent.source,
      "t" => consent.decided_at
    }

    MessageVerifier.sign(Jason.encode!(payload), signing_key(secret_key_base))
  end

  defp signing_key(secret_key_base),
    do: KeyGenerator.generate(secret_key_base, @key_salt, cache: Plug.Keys)

  defp from_payload(%{"id" => id, "v" => version, "c" => categories, "t" => decided_at} = payload)
       when is_binary(id) and is_binary(version) and is_map(categories) and
              is_integer(decided_at) do
    {:ok,
     %__MODULE__{
       id: id,
       version: version,
       categories: clean_categories(categories),
       source: clean_source(payload["s"]),
       decided_at: decided_at
     }}
  end

  defp from_payload(_payload), do: :error

  defp fresh?(%__MODULE__{decided_at: decided_at}) do
    now = System.system_time(:second)
    decided_at <= now + 300 and now - decided_at < cookie_days() * 86_400
  end

  # ── writing ───────────────────────────────────────────────────────────────

  @doc """
  Records a decision: writes it to the consent log and sets the cookie.

  `categories` is a map of category to boolean; a category left out counts as
  refused, and anything that is not a known category is ignored.

  ## Options

    * `:source` — one of `sources/0` (default `"banner"`)
    * `:user_uuid` — the signed-in user, if any
    * `:version` — the policy version (default: the current one)

  A decision equal to the one the request's cookie already holds changes
  nothing and is not logged again. A failed log write is logged and does not
  stop the cookie: the visitor's choice is honoured whether or not the audit
  row could be written.
  """
  @spec record(Plug.Conn.t(), map(), keyword()) :: {:ok, Plug.Conn.t(), t()} | {:error, term()}
  def record(conn, categories, opts \\ [])

  def record(%Plug.Conn{secret_key_base: secret} = conn, categories, opts)
      when is_binary(secret) and is_map(categories) do
    conn = fetch_cookies(conn)
    previous = decode(conn.cookies[@cookie], secret)
    version = Keyword.get_lazy(opts, :version, &Legal.get_auto_policy_version/0)

    consent = %__MODULE__{
      id: consent_id(previous),
      version: version,
      categories: clean_categories(categories),
      source: clean_source(opts[:source]),
      decided_at: System.system_time(:second)
    }

    if same_decision?(previous, consent) do
      {:ok, existing} = previous
      {:ok, conn, existing}
    else
      log(conn, consent, opts)
      {:ok, put_cookie(conn, consent, secret), consent}
    end
  end

  def record(%Plug.Conn{}, categories, _opts) when is_map(categories), do: {:error, :no_secret}

  @doc """
  Forgets the decision: every category is logged as refused and the cookie is
  removed, so the visitor is asked again.
  """
  @spec forget(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def forget(%Plug.Conn{} = conn, opts \\ []) do
    conn = fetch_cookies(conn)

    with {:ok, previous} <- decode(conn.cookies[@cookie], conn.secret_key_base),
         true <- Enum.any?(previous.categories, fn {_category, given} -> given end) do
      refused = %{
        previous
        | categories: clean_categories(%{}),
          source: clean_source(opts[:source]),
          decided_at: System.system_time(:second)
      }

      log(conn, refused, opts)
    end

    delete_resp_cookie(conn, @cookie, cookie_opts(conn))
  end

  defp consent_id({:ok, %__MODULE__{id: id}}), do: id

  defp consent_id(_previous),
    do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp same_decision?({:ok, previous}, consent),
    do: previous.categories == consent.categories and previous.version == consent.version

  defp same_decision?(_previous, _consent), do: false

  defp put_cookie(conn, consent, secret) do
    put_resp_cookie(
      conn,
      @cookie,
      encode(consent, secret),
      [max_age: cookie_days() * 86_400] ++ cookie_opts(conn)
    )
  end

  # Readable by scripts on purpose: the decision is the visitor's own, and
  # the page's scripts are what must obey it.
  defp cookie_opts(conn),
    do: [path: "/", same_site: "Lax", http_only: false, secure: conn.scheme == :https]

  defp log(conn, consent, opts) do
    if log_enabled?() do
      case ConsentLog.log_consents(consent.categories, log_opts(conn, consent, opts)) do
        {:ok, _rows} ->
          :ok

        {:error, reason} ->
          Logger.error("[Legal] consent decision was not logged: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.error("[Legal] consent decision was not logged: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ ->
      Logger.error("[Legal] consent decision was not logged: the database did not answer")
      :ok
  end

  defp log_opts(conn, consent, opts) do
    [
      user_uuid: opts[:user_uuid],
      session_id: consent.id,
      consent_version: consent.version,
      ip_address: if(log_ip?(), do: IpAddress.client_address(conn)),
      user_agent_hash: if(log_user_agent?(), do: user_agent_hash(conn)),
      metadata: %{"source" => consent.source, "gpc" => objected?(conn)}
    ]
  end

  defp user_agent_hash(conn) do
    case get_req_header(conn, "user-agent") do
      [user_agent | _] -> ConsentLog.hash_user_agent(user_agent)
      [] -> nil
    end
  end

  # Every known category, each a strict boolean: only `true` is a yes.
  defp clean_categories(categories) do
    Map.new(@categories, fn category -> {category, Map.get(categories, category) == true} end)
  end

  defp clean_source(source) when source in @sources, do: source
  defp clean_source(_source), do: "banner"
end
