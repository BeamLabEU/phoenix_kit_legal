defmodule PhoenixKit.Modules.Legal.PageStore do
  @moduledoc """
  Where generated legal pages are stored and served from, behind one
  interface. `phoenix_kit_publishing` stays a **required** dependency in
  `mix.exs` (optional would silently drop it, and the `/legal` pages, from
  every host that lists only this package), but nothing outside the
  Publishing adapter calls it: a host that leaves Publishing out (a deps
  override) or sets its own store still works. Making the dependency
  optional later is the `mix.exs` line plus an upgrade note telling hosts
  that want Publishing to list it themselves.

  `adapter/0` picks, in order:

    1. `config :phoenix_kit_legal, :page_store, MyApp.LegalPages` — a host
       module implementing this behaviour (store pages anywhere);
    2. `PhoenixKit.Modules.Legal.PageStore.Publishing` when
       `phoenix_kit_publishing` is installed (the existing behaviour:
       pages are posts in the `"legal"` group, served by Publishing at
       `/legal/:slug`);
    3. `PhoenixKit.Modules.Legal.PageStore.None` otherwise: nothing is
       stored or served, `generate_page/2` returns
       `{:error, :publishing_unavailable}`, and the consent banner, the
       consent log and `PhoenixKit.Modules.Legal.render_page/2` (rendered
       Markdown for a host to serve itself) keep working.

  The callbacks are the Publishing functions Legal has always called, with
  Publishing's shapes (post maps with `:uuid`, `:slug`, `:metadata`, …).
  """

  @type group :: String.t()
  @type post :: map()

  @callback enabled?() :: boolean()
  @callback get_primary_language() :: String.t()
  @callback enabled_language_codes() :: [String.t()]
  @callback fetch_group(group()) :: {:ok, map()} | {:error, term()}
  @callback add_group(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback remove_group(group(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_posts(group()) :: [post()]
  @callback list_posts_by_status(group(), String.t()) :: [post()]
  @callback read_post(group(), String.t()) :: {:ok, post()} | {:error, term()}
  @callback read_post(group(), String.t(), String.t(), pos_integer()) ::
              {:ok, post()} | {:error, term()}
  @callback create_post(group(), map()) :: {:ok, post()} | {:error, term()}
  @callback update_post(group(), post(), map(), keyword()) :: {:ok, post()} | {:error, term()}
  @callback publish_version(group(), String.t(), pos_integer(), keyword()) ::
              :ok | {:error, term()}
  @callback add_language_to_post(group(), String.t(), String.t(), pos_integer()) ::
              {:ok, post()} | {:error, term()}
  @callback restore_post(group(), String.t()) :: {:ok, term()} | {:error, term()}

  @publishing PhoenixKit.Modules.Publishing

  @doc "The page store in use (see the moduledoc for the order)."
  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:phoenix_kit_legal, :page_store) do
      nil -> default_adapter()
      mod -> if implements?(mod), do: mod, else: misconfigured(mod)
    end
  end

  defp default_adapter,
    do: if(publishing_installed?(), do: __MODULE__.Publishing, else: __MODULE__.None)

  # A configured store must be a loaded module with every callback; anything
  # else (`false`, a typo, a half-written module) would crash the settings
  # page or a page write later, so it is ignored (and logged) instead.
  defp implements?(mod) when is_atom(mod) and mod not in [true, false] do
    Code.ensure_loaded?(mod) and
      Enum.all?(__MODULE__.behaviour_info(:callbacks), fn {fun, arity} ->
        function_exported?(mod, fun, arity)
      end)
  end

  defp implements?(_), do: false

  # adapter/0 runs on hot paths (every consent write reaches it), so the
  # misconfiguration is logged once per configured value, not per call.
  defp misconfigured(mod) do
    key = {__MODULE__, :warned, mod}

    unless :persistent_term.get(key, false) do
      require Logger

      Logger.warning(
        "[Legal] :page_store #{inspect(mod)} is not a loaded PhoenixKit.Modules.Legal.PageStore; using the default store"
      )

      :persistent_term.put(key, true)
    end

    default_adapter()
  end

  @doc "Whether `phoenix_kit_publishing` is compiled into this application."
  @spec publishing_installed?() :: boolean()
  def publishing_installed? do
    Code.ensure_loaded?(@publishing) and function_exported?(@publishing, :read_post, 2)
  end

  @doc "Whether the store in use can store pages at all (`None` cannot)."
  @spec available?() :: boolean()
  def available?, do: adapter() != __MODULE__.None
end
