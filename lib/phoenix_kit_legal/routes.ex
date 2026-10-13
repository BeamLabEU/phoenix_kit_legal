defmodule PhoenixKit.Modules.Legal.Routes do
  @moduledoc """
  The one public route this module owns: the consent endpoint.

  Returned from `PhoenixKit.Modules.Legal.route_module/0`; core splices
  `generate/1` into the host router beside its own
  `GET /api/consent-config`.

  It pipes through `:phoenix_kit_api` rather than `:browser`: the banner
  reports a decision with `fetch`, from pages that may have no CSRF token to
  send (a statically cached page, a host layout without the meta tag). The
  trust boundary that replaces the token is in
  `PhoenixKit.Modules.Legal.Web.ConsentController`.

  Legal pages are not here and must not be: Publishing serves them.
  """

  @doc "The consent endpoint, under PhoenixKit's URL prefix."
  @spec generate(String.t()) :: Macro.t()
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_api])

        get("/api/consent", PhoenixKit.Modules.Legal.Web.ConsentController, :show)
        post("/api/consent", PhoenixKit.Modules.Legal.Web.ConsentController, :record)
        delete("/api/consent", PhoenixKit.Modules.Legal.Web.ConsentController, :forget)
      end
    end
  end
end
