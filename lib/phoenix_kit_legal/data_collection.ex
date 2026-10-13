defmodule PhoenixKit.Modules.Legal.DataCollection do
  @moduledoc """
  What the site collects about a visitor, as its own modules declare it.

  A cookie policy that lists `_ga` on a site that has never loaded Google
  Analytics is wrong in the same way as one that leaves out what the site
  does collect. So the list is not written by hand: each PhoenixKit module
  that collects something says so, and the banner, the settings page and the
  generated cookie policy all read the same answer.

  ## Declaring

  Any module implementing `PhoenixKit.Module` may export `data_collection/0`
  (no behaviour callback — it is found by name, so a module needs no
  dependency on this package):

      def data_collection do
        [
          %{
            key: "web_analytics.measurement",
            title: "Page statistics",
            description: "Which pages are visited, and from where.",
            category: "analytics",
            mode: :consent,
            active: true,
            data: ["Pages viewed", "Referring site", "Country"],
            retention: "365 days",
            storage: [
              %{name: "pk_consent", kind: "cookie", duration: "180 days", purpose: "…"}
            ]
          }
        ]
      end

    * `key` — unique and stable; the operator's choices are stored by it
    * `category` — the consent category it belongs to: `necessary`,
      `analytics`, `marketing` or `preferences`
    * `mode` — how it is collected right now: `:always` (without asking),
      `:consent` (only after a yes), `:unless_objected` (until a no) or `:off`
    * `active` — whether anything is being collected at all
    * `data`, `retention`, `storage` — what, for how long, and what is put on
      the visitor's device

  Text is the declaring module's, already translated for the current locale.
  A declaration that is not a map with a `key` and a `title` is dropped; a
  module whose `data_collection/0` raises declares nothing, and a warning
  naming it is logged.

  ## What is shown

  Everything active whose mode is not `:off` is shown by default. The operator may untick an entry
  (`hide/1`), which takes it out of the banner and the generated policy —
  and the settings page then says, next to it, that something being collected
  is not being disclosed. That choice is the operator's to make; hiding it
  silently is not.
  """

  use Gettext, backend: PhoenixKit.Modules.Legal.Gettext

  require Logger

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Settings

  @hidden_key "legal_hidden_collection"
  @fingerprint_key "legal_policy_collection_fingerprint"
  @categories ~w(necessary analytics marketing preferences)
  @modes [:always, :consent, :unless_objected, :off]
  @fetch_timeout 5_000
  # The language the fingerprint is taken in — any one would do, as long as
  # it is always the same one.
  @fingerprint_language "en"

  @type entry :: %{
          key: String.t(),
          module: String.t(),
          title: String.t(),
          description: String.t(),
          category: String.t(),
          mode: :always | :consent | :unless_objected | :off,
          active: boolean(),
          data: [String.t()],
          retention: String.t() | nil,
          storage: [
            %{name: String.t(), kind: String.t(), duration: String.t(), purpose: String.t()}
          ]
        }

  @doc "Every declaration of every enabled module, normalised, in a stable order."
  @spec declared() :: [entry()]
  def declared, do: collect(enabled_modules())

  @doc """
  The declarations of the given modules, normalised — `declared/0` over a
  list the caller chose.
  """
  @spec collect([module()]) :: [entry()]
  def collect(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(&module_entries/1)
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(&{category_rank(&1.category), &1.module, &1.key})
  end

  @doc """
  The declarations in `language`, whatever the caller's own locale is.

  Raises when they cannot be gathered; `fetch_declared/2` is the same
  without raising.
  """
  @spec declared(String.t()) :: [entry()]
  def declared(language) when is_binary(language) do
    case fetch_declared(language) do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        raise "could not gather the data collection declarations in #{inspect(language)}: " <>
                inspect(reason)
    end
  end

  @doc """
  The declarations in `language`, or why they could not be gathered.

  They are evaluated in a process of their own. A locale set for one Gettext
  backend (core sets one for `PhoenixKitWeb.Gettext` on every admin page)
  wins over the global one, and the caller cannot know which backends the
  declaring modules use — so rather than changing the caller's locale, the
  declarations run where the global locale is the only one there is.

  ## Options

    * `:modules` — the modules to ask (default: every enabled module)
    * `:timeout` — milliseconds to wait (default #{@fetch_timeout})
  """
  @spec fetch_declared(String.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def fetch_declared(language, opts \\ []) when is_binary(language) and is_list(opts) do
    modules = Keyword.get_lazy(opts, :modules, &enabled_modules/0)
    timeout = Keyword.get(opts, :timeout, @fetch_timeout)

    task =
      Task.async(fn ->
        # The task is linked to the caller, so it answers with a value
        # whatever happens instead of taking the caller down with it.
        try do
          Gettext.put_locale(language)
          {:ok, collect(modules)}
        rescue
          error -> {:error, error}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  @doc """
  What the banner and the policy show: active, collected in some way (a mode
  other than `:off`) and not hidden by the operator.
  """
  @spec listed([entry()]) :: [entry()]
  def listed(entries \\ declared()) do
    hidden = hidden_keys()
    Enum.filter(entries, &(&1.active and &1.mode != :off and &1.key not in hidden))
  end

  @doc "Listed entries grouped by consent category, every category present."
  @spec by_category([entry()]) :: %{String.t() => [entry()]}
  def by_category(entries \\ listed()) do
    grouped = Enum.group_by(entries, & &1.category)
    Map.new(@categories, &{&1, Map.get(grouped, &1, [])})
  end

  @doc """
  The keys the operator took out of the banner and the policy.

  Read through the settings cache — this runs on every page that renders the
  banner. The cache trails a write by a moment, so anything that has just
  written the list, or is about to change it, asks for `fresh: true`, which
  reads the setting itself.
  """
  @spec hidden_keys(keyword()) :: [String.t()]
  def hidden_keys(opts \\ []) do
    stored =
      if Keyword.get(opts, :fresh, false),
        do: Legal.fresh_json_setting(@hidden_key, %{"items" => []}),
        else: Settings.get_json_setting_cached(@hidden_key, %{"items" => []})

    case stored do
      %{"items" => items} when is_list(items) -> Enum.filter(items, &is_binary/1)
      _ -> []
    end
  rescue
    # Settings that cannot be read hide nothing: the list errs towards telling
    # visitors more.
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Takes an entry out of the banner and the policy. Answers `{:ok, keys}` with
  the hidden keys as they now are.
  """
  @spec hide(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def hide(key, opts \\ []) when is_binary(key),
    do: put_hidden(Enum.uniq([key | hidden_keys(fresh: true)]), opts)

  @doc "Puts an entry back. Answers `{:ok, keys}` with the hidden keys as they now are."
  @spec show(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def show(key, opts \\ []) when is_binary(key),
    do: put_hidden(List.delete(hidden_keys(fresh: true), key), opts)

  # `opts` say who made the change (`:actor_uuid`, `:source`) in the
  # settings history.
  #
  # The list is read fresh before it is changed and handed back after: the
  # settings cache trails a write, and a caller that re-read it would see the
  # list as it was, and undo nothing on the next click.
  defp put_hidden(keys, opts) do
    keys = Enum.sort(keys)

    case Legal.put_setting(:json, @hidden_key, %{"items" => keys}, opts) do
      {:ok, _setting} -> {:ok, keys}
      error -> error
    end
  end

  @doc """
  What needs the operator's attention about one entry, as sentences — empty
  when nothing does.
  """
  @spec warnings(entry(), keyword()) :: [String.t()]
  def warnings(entry, opts \\ []) do
    hidden = Keyword.get_lazy(opts, :hidden, &hidden_keys/0)
    widget? = Keyword.get_lazy(opts, :widget_enabled, &Legal.consent_widget_enabled?/0)

    [
      entry.active and entry.key in hidden and
        gettext("This is being collected, but visitors are not told about it."),
      entry.active and entry.mode == :consent and not widget? and
        gettext("This waits for consent, but the banner is off, so nothing is collected.")
    ]
    |> Enum.filter(&is_binary/1)
  end

  @doc "How an entry is collected, in words."
  @spec mode_label(atom()) :: String.t()
  def mode_label(:always), do: gettext("Collected without asking")
  def mode_label(:consent), do: gettext("Only after the visitor agrees")
  def mode_label(:unless_objected), do: gettext("Until the visitor objects")
  def mode_label(:off), do: gettext("Not collected")

  @doc "The legal ground an entry's mode stands on, in words, for the policy."
  @spec basis_label(atom()) :: String.t()
  def basis_label(:consent), do: gettext("Your consent")
  def basis_label(:unless_objected), do: gettext("Our legitimate interest; you may object")
  def basis_label(_mode), do: gettext("Our legitimate interest")

  @doc """
  A short hash of what the policy prints about the listed entries: what is
  collected and how (`key`, `mode`, `category`, `data`, `retention`) and what
  is stored on the device (each item's `name`, `kind` and `duration`). It
  changes when any of those does, and not when a title or a description is
  reworded.

  Some of that is translated text, so the same list hashes differently in
  two languages. `fingerprint/0` always takes it in one.
  """
  @spec fingerprint([entry()]) :: String.t()
  def fingerprint(entries) when is_list(entries) do
    entries
    |> Enum.map(fn entry ->
      {entry.key, entry.mode, entry.category, entry.retention, entry.data,
       Enum.map(entry.storage, &{&1.name, &1.kind, &1.duration})}
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  The fingerprint of what is listed right now — the same whoever is looking,
  in whatever language. Raises when the declarations cannot be gathered.
  """
  @spec fingerprint() :: String.t()
  def fingerprint, do: @fingerprint_language |> declared() |> listed() |> fingerprint()

  @doc "Remembers what the cookie policy was generated from."
  @spec remember_generated(keyword()) :: {:ok, term()} | {:error, term()}
  def remember_generated(opts \\ []) do
    with {:ok, entries} <- fetch_declared(@fingerprint_language) do
      Legal.put_setting(:string, @fingerprint_key, entries |> listed() |> fingerprint(), opts)
    end
  end

  @doc """
  Whether what the site collects has changed since the cookie policy was
  generated. `false` when no policy was ever generated from a list, and when
  the list cannot be gathered to compare.
  """
  @spec policy_outdated?() :: boolean()
  def policy_outdated? do
    with stored when is_binary(stored) and stored != "" <-
           Settings.get_setting_cached(@fingerprint_key, nil),
         {:ok, entries} <- fetch_declared(@fingerprint_language) do
      stored != entries |> listed() |> fingerprint()
    else
      {:error, reason} ->
        Logger.warning(
          "[Legal] could not compare the cookie policy with what is declared: " <>
            inspect(reason)
        )

        false

      _ ->
        false
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp enabled_modules do
    ModuleRegistry.enabled_modules()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp module_entries(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :data_collection, 0) do
      module_key = module.module_key()

      module.data_collection()
      |> List.wrap()
      |> Enum.flat_map(&normalize(&1, module_key))
    else
      []
    end
  rescue
    error -> undeclared(module, inspect(error.__struct__))
  catch
    :exit, _ -> undeclared(module, "exit")
  end

  # One module's broken declaration must not take the banner or the policy
  # down, but it must not disappear quietly either. The module is named; the
  # error's own text and stacktrace are left out, as they may hold anything.
  defp undeclared(module, why) do
    Logger.warning(
      "[Legal] #{inspect(module)}.data_collection/0 failed (#{why}); it declares nothing"
    )

    []
  end

  defp normalize(%{} = raw, module_key) do
    key = text(fetch(raw, :key))
    title = text(fetch(raw, :title))

    if key == "" or title == "" do
      []
    else
      [
        %{
          key: key,
          module: module_key,
          title: title,
          description: text(fetch(raw, :description)),
          category: category(fetch(raw, :category)),
          mode: mode(fetch(raw, :mode)),
          active: fetch(raw, :active) != false,
          data: raw |> fetch(:data) |> texts(),
          retention: raw |> fetch(:retention) |> text() |> blank_to_nil(),
          storage: raw |> fetch(:storage) |> List.wrap() |> Enum.flat_map(&storage/1)
        }
      ]
    end
  end

  defp normalize(_raw, _module_key), do: []

  defp storage(%{} = raw) do
    case text(fetch(raw, :name)) do
      "" ->
        []

      name ->
        [
          %{
            name: name,
            kind: text(fetch(raw, :kind) || "cookie"),
            duration: text(fetch(raw, :duration)),
            purpose: text(fetch(raw, :purpose))
          }
        ]
    end
  end

  defp storage(_raw), do: []

  # A declaration may be written with atom or string keys.
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp texts(values) when is_list(values),
    do: values |> Enum.map(&text/1) |> Enum.reject(&(&1 == ""))

  defp texts(_values), do: []

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp category(value) when value in @categories, do: value

  defp category(value) when is_atom(value) and not is_nil(value),
    do: category(Atom.to_string(value))

  defp category(_value), do: "analytics"

  defp mode(value) when value in @modes, do: value

  defp mode(value) when is_binary(value),
    do: Enum.find(@modes, :always, &(Atom.to_string(&1) == value))

  defp mode(_value), do: :always

  defp category_rank(category), do: Enum.find_index(@categories, &(&1 == category)) || 99
end
