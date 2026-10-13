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
  module whose `data_collection/0` raises declares nothing.

  ## What is shown

  Everything active is shown by default. The operator may untick an entry
  (`hide/1`), which takes it out of the banner and the generated policy —
  and the settings page then says, next to it, that something being collected
  is not being disclosed. That choice is the operator's to make; hiding it
  silently is not.
  """

  use Gettext, backend: PhoenixKit.Modules.Legal.Gettext

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Settings

  @hidden_key "legal_hidden_collection"
  @fingerprint_key "legal_policy_collection_fingerprint"
  @categories ~w(necessary analytics marketing preferences)
  @modes [:always, :consent, :unless_objected, :off]

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

  @doc "The declarations in `language`, whatever the caller's own locale is."
  @spec declared(String.t()) :: [entry()]
  def declared(language) when is_binary(language) do
    previous = Gettext.get_locale()
    Gettext.put_locale(language)

    try do
      declared()
    after
      Gettext.put_locale(previous)
    end
  end

  @doc "What the banner and the policy show: active and not hidden by the operator."
  @spec listed([entry()]) :: [entry()]
  def listed(entries \\ declared()) do
    hidden = hidden_keys()
    Enum.filter(entries, &(&1.active and &1.key not in hidden))
  end

  @doc "Listed entries grouped by consent category, every category present."
  @spec by_category([entry()]) :: %{String.t() => [entry()]}
  def by_category(entries \\ listed()) do
    grouped = Enum.group_by(entries, & &1.category)
    Map.new(@categories, &{&1, Map.get(grouped, &1, [])})
  end

  @doc "The keys the operator took out of the banner and the policy."
  @spec hidden_keys() :: [String.t()]
  def hidden_keys do
    case Settings.get_json_setting_cached(@hidden_key, %{"items" => []}) do
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

  @doc "Takes an entry out of the banner and the policy."
  @spec hide(String.t()) :: {:ok, term()} | {:error, term()}
  def hide(key) when is_binary(key), do: put_hidden(Enum.uniq([key | hidden_keys()]))

  @doc "Puts an entry back."
  @spec show(String.t()) :: {:ok, term()} | {:error, term()}
  def show(key) when is_binary(key), do: put_hidden(List.delete(hidden_keys(), key))

  defp put_hidden(keys) do
    Settings.update_json_setting_with_module(
      @hidden_key,
      %{"items" => Enum.sort(keys)},
      Legal.module_key()
    )
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
  A short hash of what is listed — the same until what the site tells
  visitors would read differently.
  """
  @spec fingerprint([entry()]) :: String.t()
  def fingerprint(entries \\ listed()) do
    entries
    |> Enum.map(
      &{&1.key, &1.mode, &1.category, &1.retention, Enum.map(&1.storage, fn s -> s.name end)}
    )
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Remembers what the cookie policy was generated from."
  @spec remember_generated() :: {:ok, term()} | {:error, term()}
  def remember_generated do
    Settings.update_setting_with_module(@fingerprint_key, fingerprint(), Legal.module_key())
  end

  @doc """
  Whether what the site collects has changed since the cookie policy was
  generated. `false` when no policy was ever generated from a list.
  """
  @spec policy_outdated?() :: boolean()
  def policy_outdated? do
    case Settings.get_setting_cached(@fingerprint_key, nil) do
      stored when is_binary(stored) and stored != "" -> stored != fingerprint()
      _ -> false
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
    _ -> []
  catch
    :exit, _ -> []
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
