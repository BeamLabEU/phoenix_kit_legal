defmodule PhoenixKitLegal.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_legal"

  def project do
    [
      app: :phoenix_kit_legal,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PhoenixKit Legal",
      source_url: @source_url,
      description:
        "Legal compliance module for PhoenixKit — GDPR/CCPA legal pages, cookie consent, consent logging"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix_kit, "~> 1.7", path: "/app", override: true},
      {:phoenix_kit_publishing, github: "BeamLabEU/phoenix_kit_publishing"},
      {:phoenix_live_view, "~> 1.0"},
      {:ecto_sql, "~> 3.10"},
      {:gettext, "~> 1.0"}
    ]
  end
end
