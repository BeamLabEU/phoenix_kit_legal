defmodule PhoenixKit.Modules.Legal.PageStore.Publishing do
  @moduledoc """
  `PhoenixKit.Modules.Legal.PageStore` over `phoenix_kit_publishing`: every
  call goes straight to `PhoenixKit.Modules.Publishing`. Chosen
  automatically when Publishing is installed, so hosts that have it behave
  exactly as before Publishing became optional.
  """

  @behaviour PhoenixKit.Modules.Legal.PageStore

  # Publishing is an optional dependency: absent at compile time in a host
  # without it, where this adapter is never selected.
  @compile {:no_warn_undefined, PhoenixKit.Modules.Publishing}

  alias PhoenixKit.Modules.Publishing

  @impl true
  def enabled?, do: Publishing.enabled?()
  @impl true
  def get_primary_language, do: Publishing.get_primary_language()
  @impl true
  def enabled_language_codes, do: Publishing.enabled_language_codes()
  @impl true
  def fetch_group(group), do: Publishing.fetch_group(group)
  @impl true
  def add_group(name, opts), do: Publishing.add_group(name, opts)
  @impl true
  def remove_group(group, opts), do: Publishing.remove_group(group, opts)
  @impl true
  def list_posts(group), do: Publishing.list_posts(group)
  @impl true
  def list_posts_by_status(group, status), do: Publishing.list_posts_by_status(group, status)
  @impl true
  def read_post(group, slug), do: Publishing.read_post(group, slug)
  @impl true
  def read_post(group, slug, language, version),
    do: Publishing.read_post(group, slug, language, version)

  @impl true
  def create_post(group, attrs), do: Publishing.create_post(group, attrs)
  @impl true
  def update_post(group, post, attrs, opts), do: Publishing.update_post(group, post, attrs, opts)
  @impl true
  def publish_version(group, uuid, version, opts),
    do: Publishing.publish_version(group, uuid, version, opts)

  @impl true
  def add_language_to_post(group, uuid, language, version),
    do: Publishing.add_language_to_post(group, uuid, language, version)

  @impl true
  def restore_post(group, uuid), do: Publishing.restore_post(group, uuid)
end
