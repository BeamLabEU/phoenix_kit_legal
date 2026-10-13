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

  Both read the request — a cookie and a header — and make no database query
  of their own, so they are safe on a hot path. The one setting they need
  (how long a decision lasts) comes through core's cached reader, which
  refills from the database when the cache has no entry for it: a
  settings-cache refill at most, never a query per request.

  ## The cookie

  `pk_consent`, set by the server, readable by JavaScript, `SameSite=Lax`.
  Its value is the decision as JSON, signed with a key derived from the
  endpoint's `secret_key_base` (`Plug.Crypto.MessageVerifier`), so a visitor
  can read their decision but a script cannot forge one the server will
  believe. An unsigned, tampered or expired cookie reads as no decision.

  It carries no identity: a random consent ID, the policy version, the
  categories, when and where the decision was made, and one boolean (`"u"`)
  saying whether the log entry for it names a user.

  ## The record

  `record/3` writes one `phoenix_kit_consent_logs` row per category, keyed by
  the consent ID (and the user's UUID when signed in). The visitor's address
  and a hash of their User-Agent are added only when
  `legal_consent_log_ip` / `legal_consent_log_user_agent` ask for them; both
  are off by default. A decision identical to the one the visitor's cookie
  already holds is not written twice — except once, when it was made signed
  out and arrives again signed in, so the log can say whose it is.
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
  defstruct [:id, :version, :categories, :source, :decided_at, with_user: false]

  @type status :: :granted | :denied | :unknown
  @type t :: %__MODULE__{
          id: String.t(),
          version: String.t(),
          categories: %{String.t() => boolean()},
          source: String.t(),
          decided_at: integer(),
          with_user: boolean()
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

  Only the keys present in `attrs` are written; a setting whose key is left
  out stays as it was. `:cookie_days` must be an integer, or a string of one,
  from 1 to #{@max_days} — anything else is `{:error, :invalid_days}`, and
  nothing at all is written.

  `opts` go to the settings writer: `:actor_uuid` and `:source` say who made
  the change in the settings history.
  """
  @spec update_settings(map(), keyword()) :: :ok | {:error, term()}
  def update_settings(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, writes} <- settings_writes(attrs) do
      Enum.reduce_while(writes, :ok, &write_setting(&1, &2, opts))
    end
  end

  defp write_setting({key, value}, :ok, opts) do
    case Legal.put_setting(:string, key, value, opts) do
      {:ok, _} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @boolean_settings [
    log: @log_key,
    log_ip: @log_ip_key,
    log_user_agent: @log_user_agent_key,
    reload_on_withdrawal: @reload_key
  ]

  # What `update_settings/2` would write, as `{key, value}` pairs, without
  # writing it — so everything is checked before the first write, and so the
  # rules can be tested without a database.
  @doc false
  @spec settings_writes(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, :invalid_days}
  def settings_writes(attrs) when is_map(attrs) do
    booleans =
      for {name, key} <- @boolean_settings, Map.has_key?(attrs, name) do
        {key, to_string(Map.fetch!(attrs, name) == true)}
      end

    case Map.fetch(attrs, :cookie_days) do
      :error ->
        {:ok, booleans}

      {:ok, value} ->
        with {:ok, days} <- valid_days(value) do
          {:ok, booleans ++ [{@days_key, Integer.to_string(days)}]}
        end
    end
  end

  # Stricter than reading: a stored value that is out of range is clamped so
  # the site keeps working, but a new one is refused so the operator is told.
  defp valid_days(days) when is_integer(days) and days >= 1 and days <= @max_days, do: {:ok, days}

  defp valid_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} -> valid_days(days)
      _ -> {:error, :invalid_days}
    end
  end

  defp valid_days(_value), do: {:error, :invalid_days}

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
  or an endpoint without a `secret_key_base`. So does anything that is not a
  request at all: this is called on other modules' hot paths and never raises.
  """
  @spec read(term()) :: {:ok, t()} | :none
  def read(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn)
    decode(conn.cookies[@cookie], conn.secret_key_base)
  end

  def read(_other), do: :none

  @doc """
  What the visitor decided about one category.

  `necessary` is always `:granted`; an unknown category is `:unknown`, and so
  is any other pair of arguments (an atom category, something that is not a
  request) — a caller on a hot path gets an answer, never an exception.
  """
  @spec status(term(), term()) :: status()
  def status(_conn, "necessary"), do: :granted

  def status(%Plug.Conn{} = conn, category) when is_binary(category) do
    case read(conn) do
      {:ok, %__MODULE__{categories: %{^category => true}}} -> :granted
      {:ok, %__MODULE__{categories: %{^category => false}}} -> :denied
      _ -> :unknown
    end
  end

  def status(_conn, _category), do: :unknown

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
      "t" => consent.decided_at,
      "u" => consent.with_user
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
       decided_at: decided_at,
       # Absent on cookies issued before the flag existed: nobody was named.
       with_user: payload["u"] == true
     }}
  end

  defp from_payload(_payload), do: :error

  defp fresh?(%__MODULE__{decided_at: decided_at}) do
    now = System.system_time(:second)
    decided_at <= now + 300 and now - decided_at < cookie_days() * 86_400
  end

  # ── writing ───────────────────────────────────────────────────────────────

  # The same choices under the same policy version. The time and the source
  # of a decision do not make it a new one.
  defguardp is_same_decision(previous, consent)
            when previous.categories == consent.categories and
                   previous.version == consent.version

  @doc """
  Records a decision: writes it to the consent log and sets the cookie.

  `categories` is a map of category to boolean; a category left out counts as
  refused, and anything that is not a known category is ignored.

  ## Options

    * `:source` — one of `sources/0` (default `"banner"`)
    * `:user_uuid` — the signed-in user, if any
    * `:version` — the policy version (default: the current one)

  A decision equal to the one the request's cookie already holds changes
  nothing and is not logged again — with one exception. A decision made
  signed out is logged without a user; when it arrives again with a
  `:user_uuid`, it is logged once more, with the user, and the cookie is
  re-issued marked as attributed, so it happens only once.

  A failed log write is logged and does not stop the cookie: the visitor's
  choice is honoured whether or not the audit row could be written.
  """
  @spec record(Plug.Conn.t(), map(), keyword()) :: {:ok, Plug.Conn.t(), t()} | {:error, term()}
  def record(conn, categories, opts \\ [])

  def record(%Plug.Conn{secret_key_base: secret} = conn, categories, opts)
      when is_binary(secret) and is_map(categories) do
    conn = fetch_cookies(conn)
    previous = decode(conn.cookies[@cookie], secret)
    version = Keyword.get_lazy(opts, :version, &Legal.get_auto_policy_version/0)
    user? = is_binary(opts[:user_uuid])

    consent = %__MODULE__{
      id: consent_id(previous),
      version: version,
      categories: clean_categories(categories),
      source: clean_source(opts[:source]),
      decided_at: System.system_time(:second),
      with_user: user?
    }

    case previous do
      {:ok, existing} when is_same_decision(existing, consent) ->
        if user? and not existing.with_user do
          # The decision itself is unchanged, so it keeps its time and source;
          # only who made it is new.
          attributed = %{existing | with_user: true}
          log(conn, attributed, opts)
          {:ok, put_cookie(conn, attributed, secret), attributed}
        else
          {:ok, conn, existing}
        end

      _ ->
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
    do: [path: "/", same_site: "Lax", http_only: false, secure: https?(conn)]

  # Behind a proxy that ends TLS the request reaches the endpoint as plain
  # http; the proxy says what the visitor used.
  defp https?(conn) do
    conn.scheme == :https or
      List.first(get_req_header(conn, "x-forwarded-proto")) == "https"
  end

  defp log(conn, consent, opts) do
    if log_enabled?() do
      case ConsentLog.log_consents(consent.categories, log_opts(conn, consent, opts)) do
        {:ok, _rows} ->
          :ok

        {:error, reason} ->
          Logger.error("[Legal] consent decision was not logged: #{describe_failure(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.error("[Legal] consent decision was not logged: #{describe_failure(error)}")
      :ok
  catch
    :exit, _ ->
      Logger.error("[Legal] consent decision was not logged: the database did not answer")
      :ok
  end

  # Why a log write failed, for the application log. A rejected entry is a
  # changeset holding the visitor's address and the user's ID, and several
  # exceptions print the changeset or the query parameters in their message —
  # so only field names, validation messages and the exception's name are
  # written, never the values.
  @doc false
  @spec describe_failure(term()) :: String.t()
  def describe_failure(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {field, {message, _details}} -> "#{field} #{message}" end)
  end

  def describe_failure({:error, reason}), do: describe_failure(reason)

  def describe_failure(reasons) when is_list(reasons) and reasons != [] do
    reasons |> Enum.map(&describe_failure/1) |> Enum.uniq() |> Enum.join("; ")
  end

  def describe_failure(%{__exception__: true, __struct__: module}), do: inspect(module)
  def describe_failure(reason) when is_atom(reason), do: inspect(reason)
  def describe_failure(_reason), do: "unexpected error"

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
