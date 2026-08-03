defmodule PhoenixKitLegal do
  @moduledoc """
  Legal compliance module for PhoenixKit.

  Provides GDPR/CCPA compliant legal page generation, cookie consent management,
  and consent logging.

  ## Features

  - Multi-framework compliance (GDPR, CCPA, LGPD, PIPEDA, etc.)
  - Cookie consent widget with Google Consent Mode v2
  - Legal page generation via Publishing module
  - Consent logging for audit trail

  ## Dependencies

  - `phoenix_kit` ~> 1.7.227 (owns the `/api/consent-config` endpoint this
    package used to serve; see AGENTS.md, "Consent Config Endpoint Contract")
  - `phoenix_kit_publishing` (for page generation and public page rendering)
  """

  @version Mix.Project.config()[:version]

  def version, do: @version
end
