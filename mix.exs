defmodule PhoenixKitLegal.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_legal"

  def project do
    [
      app: :phoenix_kit_legal,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      elixirc_options: [ignore_module_conflict: true],
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Legal compliance module for PhoenixKit — GDPR/CCPA legal pages, cookie consent, consent logging",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitLegal",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, and core infrastructure.
      {:phoenix_kit, "~> 1.7"},

      # Publishing module for storing generated legal pages as posts.
      {:phoenix_kit_publishing, "~> 0.1"},

      # LiveView for admin settings page.
      {:phoenix_live_view, "~> 1.0"},

      # Ecto for consent log schema.
      {:ecto_sql, "~> 3.10"},

      # Internationalization for legal page templates.
      {:gettext, "~> 1.0"},

      # Code quality (dev/test only)
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
    ]
  end
end
