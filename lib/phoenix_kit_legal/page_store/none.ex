defmodule PhoenixKit.Modules.Legal.PageStore.None do
  @moduledoc """
  `PhoenixKit.Modules.Legal.PageStore` for a host without
  `phoenix_kit_publishing`: stores nothing. Reads answer "nothing there",
  writes `{:error, :publishing_unavailable}`. The primary language is
  English and English is the only enabled language.
  """

  @behaviour PhoenixKit.Modules.Legal.PageStore

  @unavailable {:error, :publishing_unavailable}

  @impl true
  def enabled?, do: false
  @impl true
  def get_primary_language, do: "en"
  @impl true
  def enabled_language_codes, do: ["en"]
  @impl true
  def fetch_group(_group), do: @unavailable
  @impl true
  def add_group(_name, _opts), do: @unavailable
  @impl true
  def remove_group(_group, _opts), do: @unavailable
  @impl true
  def list_posts(_group), do: []
  @impl true
  def list_posts_by_status(_group, _status), do: []
  @impl true
  def read_post(_group, _slug), do: {:error, :not_found}
  @impl true
  def read_post(_group, _slug, _language, _version), do: {:error, :not_found}
  @impl true
  def create_post(_group, _attrs), do: @unavailable
  @impl true
  def update_post(_group, _post, _attrs, _opts), do: @unavailable
  @impl true
  def publish_version(_group, _uuid, _version, _opts), do: @unavailable
  @impl true
  def add_language_to_post(_group, _uuid, _language, _version), do: @unavailable
  @impl true
  def restore_post(_group, _uuid), do: @unavailable
end
