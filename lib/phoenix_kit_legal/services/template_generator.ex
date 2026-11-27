defmodule PhoenixKit.Modules.Legal.TemplateGenerator do
  @moduledoc """
  Generates legal page content from EEx templates.

  Templates are loaded from:
  1. Parent application's `priv/legal_templates/` (for customization)
  2. PhoenixKit's bundled templates in `priv/legal_templates/`

  ## Template Variables

  All templates receive these variables:
    * `@company_name` - Company name
    * `@company_address` - Company address
    * `@company_country` - Company country
    * `@company_website` - Company website URL
    * `@registration_number` - Company registration number
    * `@vat_number` - VAT number
    * `@dpo_name` - Data Protection Officer name
    * `@dpo_email` - DPO email
    * `@dpo_phone` - DPO phone
    * `@dpo_address` - DPO address
    * `@frameworks` - List of selected framework IDs
    * `@effective_date` - Current date in ISO format
    * `@language` - Language code the page is rendered in
    * `@data_collection` - What the site's modules declare they collect: a map
      of consent category (`"necessary"`, `"analytics"`, `"marketing"`,
      `"preferences"`) to the listed entries, each with `title`,
      `description`, `data`, `retention`, `storage` and its legal `basis` in
      words. Every category is always present; a context that leaves the
      variable out gets all four empty.

  ## Usage

      context = %{
        company_name: "Acme Corp",
        company_address: "123 Main St",
        effective_date: "2025-01-15"
      }

      {:ok, content} = TemplateGenerator.render("privacy_policy.eex", context)
  """

  require Logger

  alias PhoenixKit.Modules.Legal.DataCollection

  @templates_dir "legal_templates"

  @doc """
  Render a template with the given context.

  ## Parameters
    * `template_name` - Template filename (e.g., "privacy_policy.eex")
    * `context` - Map of variables to pass to the template
    * `language` - Language code (default: "en")

  ## Returns
    * `{:ok, content}` - Rendered content
    * `{:error, reason}` - Error reason
  """
  @spec render(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def render(template_name, context, language \\ "en") when is_map(context) do
    template_path = get_template_path(template_name, language)
    # A context built before templates read `@data_collection` (a host
    # calling this directly) still renders: it declares nothing.
    context_with_language =
      context
      |> Map.put(:language, language)
      |> put_new_data_collection()

    if File.exists?(template_path) do
      try do
        # Convert context map to keyword list for EEx
        assigns = Enum.map(context_with_language, fn {k, v} -> {to_atom(k), v} end)
        content = EEx.eval_file(template_path, assigns: assigns)
        {:ok, content}
      rescue
        e in EEx.SyntaxError ->
          Logger.error("Template syntax error in #{template_name}: #{inspect(e)}")
          {:error, {:syntax_error, e.message}}

        e ->
          Logger.error("Template rendering error in #{template_name}: #{inspect(e)}")
          {:error, {:render_error, Exception.message(e)}}
      end
    else
      Logger.warning("Template not found: #{template_path}")
      {:error, :template_not_found}
    end
  end

  @doc """
  Get the full path to a template file, with language-aware lookup.

  See `resolve/2` for the order; this returns only the path.
  """
  @spec get_template_path(String.t(), String.t()) :: String.t()
  def get_template_path(template_name, language \\ "en") do
    template_name |> resolve(language) |> elem(0)
  end

  @doc """
  The template file a page in `language` is rendered from, and the locale
  that file is in: `{path, locale}`.

  The host's own text wins over the bundled one. For `"et-EE"` it tries, in
  order:

    1. the parent app's `{name}.et-EE.eex`, then its `{name}.et.eex`;
    2. the parent app's English `{name}.eex`, when the host overrode it — a
       host that rewrote its English policy and wrote no Estonian one gets
       its own English text, not the bundled Estonian translation of ours;
    3. the bundled `{name}.et-EE.eex`, then `{name}.et.eex`;
    4. the bundled English `{name}.eex`.

  The locale in the answer is the file's (`"en"` after steps 2 and 4). The
  bundled templates exist in English, Estonian (`et`) and Russian (`ru`).
  """
  @spec resolve(String.t(), String.t() | nil) :: {String.t(), String.t()}
  def resolve(template_name, language),
    do: resolve(template_name, language, &get_parent_template_path/1)

  @doc false
  # `parent` looks a file name up in the host app (`{:ok, path} | :error`);
  # injectable so the order can be tested without a host app.
  @spec resolve(String.t(), String.t() | nil, (String.t() -> {:ok, String.t()} | :error)) ::
          {String.t(), String.t()}
  def resolve(template_name, language, parent) do
    candidates = language |> locale_candidates() |> Enum.reject(&(&1 == "en"))

    find = fun_lookup(template_name, candidates)

    find.(parent) ||
      host_english(template_name, candidates, parent) ||
      find.(&get_phoenix_kit_lang_template_path/1) ||
      {get_phoenix_kit_template_path(template_name), "en"}
  end

  defp fun_lookup(template_name, candidates) do
    fn lookup ->
      Enum.find_value(candidates, fn locale ->
        case lookup.(localized_template_name(template_name, locale)) do
          {:ok, path} -> {path, locale}
          :error -> nil
        end
      end)
    end
  end

  # The host's own English template, if it has one.
  defp host_english(template_name, _candidates, parent) do
    case parent.(template_name) do
      {:ok, path} -> {path, "en"}
      :error -> nil
    end
  end

  @doc """
  The locale a page in `language` would actually be written in (see
  `resolve/2`) — `"en"` when no template exists for the language.
  """
  @spec resolved_locale(String.t(), String.t() | nil) :: String.t()
  def resolved_locale(template_name, language),
    do: template_name |> resolve(language) |> elem(1)

  @doc """
  A short fingerprint of the template a page in `language` is rendered from
  (`"sha256:<12 hex>"` of the resolved file's bytes), or `nil` when the file
  cannot be read. It changes whenever the template text does — a new
  package release or a host override — so a record of "which text was
  accepted" can name it.
  """
  @spec template_version(String.t(), String.t() | nil) :: String.t() | nil
  def template_version(template_name, language) do
    {path, _locale} = resolve(template_name, language)

    case File.read(path) do
      {:ok, bytes} ->
        hex = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        "sha256:" <> binary_part(hex, 0, 12)

      {:error, _} ->
        nil
    end
  end

  # "et-EE" → ["et-EE", "et"]; "ru" → ["ru"]; junk or nil → [].
  defp locale_candidates(language) when is_binary(language) do
    language = String.trim(language)

    if language =~ ~r/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/ do
      [first | _rest] = String.split(language, ["-", "_"])
      base = String.downcase(first)
      # "ET-ee" → "et-ee", then "et": the language subtag in the catalogue's
      # case, so a case-insensitive filesystem cannot answer "ET".
      full =
        base <> binary_part(language, byte_size(first), byte_size(language) - byte_size(first))

      Enum.uniq([full, base])
    else
      []
    end
  end

  defp locale_candidates(_), do: []

  @doc """
  List all available templates.
  """
  @spec list_available_templates() :: list(String.t())
  def list_available_templates do
    phoenix_kit_templates = list_phoenix_kit_templates()
    parent_templates = list_parent_templates()

    (phoenix_kit_templates ++ parent_templates)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Check if a template exists.
  """
  @spec template_exists?(String.t()) :: boolean()
  def template_exists?(template_name) do
    get_template_path(template_name)
    |> File.exists?()
  end

  # ===================================
  # PRIVATE HELPERS
  # ===================================

  defp localized_template_name(template_name, language) do
    # "privacy_policy.eex" + "de" -> "privacy_policy.de.eex"
    base = Path.rootname(template_name)
    "#{base}.#{language}.eex"
  end

  defp get_phoenix_kit_lang_template_path(template_name) do
    path = get_phoenix_kit_template_path(template_name)
    if File.exists?(path), do: {:ok, path}, else: :error
  end

  defp get_parent_template_path(template_name) do
    case PhoenixKit.Config.get_parent_app() do
      nil ->
        :error

      app ->
        try do
          priv_dir = Application.app_dir(app, "priv")
          path = Path.join([priv_dir, @templates_dir, template_name])

          if File.exists?(path) do
            {:ok, path}
          else
            :error
          end
        rescue
          _ -> :error
        end
    end
  end

  defp get_phoenix_kit_template_path(template_name) do
    priv_dir = :code.priv_dir(:phoenix_kit_legal) |> to_string()
    Path.join([priv_dir, @templates_dir, template_name])
  rescue
    _ ->
      # Fallback for development
      Path.join(["priv", @templates_dir, template_name])
  end

  defp list_phoenix_kit_templates do
    priv_dir = :code.priv_dir(:phoenix_kit_legal) |> to_string()
    templates_dir = Path.join(priv_dir, @templates_dir)

    if File.dir?(templates_dir) do
      templates_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".eex"))
    else
      []
    end
  rescue
    _ -> []
  end

  defp list_parent_templates do
    case PhoenixKit.Config.get_parent_app() do
      nil ->
        []

      app ->
        try do
          priv_dir = Application.app_dir(app, "priv")
          templates_dir = Path.join(priv_dir, @templates_dir)

          if File.dir?(templates_dir) do
            templates_dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".eex"))
          else
            []
          end
        rescue
          _ -> []
        end
    end
  end

  defp put_new_data_collection(context) do
    if Map.has_key?(context, :data_collection) or Map.has_key?(context, "data_collection") do
      context
    else
      Map.put(context, :data_collection, DataCollection.by_category([]))
    end
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)
end
