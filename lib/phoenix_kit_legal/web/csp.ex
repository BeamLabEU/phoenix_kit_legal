defmodule PhoenixKit.Modules.Legal.Web.CSP do
  @moduledoc false
  # The host's Content-Security-Policy nonce for an inline `<style>` or `<script>` this
  # module renders. Core keeps it (`PhoenixKitWeb.CSP`); a core that predates that module
  # has none to give, and `nonce={nil}` renders no attribute.

  @doc """
  The nonce of the current page for `kind` (`:script` or `:style`), or `nil`.
  """
  @spec nonce(:script | :style) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    if Code.ensure_loaded?(PhoenixKitWeb.CSP) and function_exported?(PhoenixKitWeb.CSP, :nonce, 1) do
      # `apply/3`: the published core has no such module to call by name.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(PhoenixKitWeb.CSP, :nonce, [kind]) do
        nonce when is_binary(nonce) and nonce != "" -> nonce
        _ -> nil
      end
    end
  end
end
