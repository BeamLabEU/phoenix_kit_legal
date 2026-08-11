defmodule PhoenixKitLegal.MixProject do
  use Mix.Project

  @version "0.4.0"
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
      dialyzer: [plt_add_apps: [:mix, :phoenix_kit]],

      # Docs
      name: "PhoenixKitLegal",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, and core infrastructure.
      # 1.7.184 adds `disabled`/`wrapper_class`/`title`/`:description` to
      # `PhoenixKitWeb.Components.Core.Checkbox`, used here. 1.7.189 adds the
      # runtime schema-prefix support `PhoenixKit.SchemaPrefix` relies on.
      # 1.7.227 is a hard floor, not a preference: it owns
      # `PhoenixKitWeb.Controllers.ConsentConfigController`, which this package
      # defined through 0.1.9 and no longer does. Core declares that route
      # whenever this module is loaded, so on an older core the route resolves to
      # a module that exists nowhere — UndefinedFunctionError, on every request
      # the bundled JS makes. See AGENTS.md, "Consent Config Endpoint Contract".
      {:phoenix_kit, "~> 2.0"},
      # Build MDEx's Rust NIF from source on OTP versions it ships no
      # compatible precompiled NIF for — same escape hatch core's mix.exs
      # carries: MDEx's force_build requires rustler itself, not just
      # rustler_precompiled. Optional: pulled only to compile the NIF.
      {:rustler, ">= 0.0.0", optional: true},

      # Publishing module for storing generated legal pages as posts.
      {:phoenix_kit_publishing, "~> 0.5"},

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
      # Tags in this repo are bare version numbers (`0.1.8`), not `v`-prefixed —
      # see AGENTS.md. A "v#{@version}" ref points at a tag that has never
      # existed, which 404s every "Source" link on HexDocs.
      source_ref: @version,
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
    ]
  end
end
