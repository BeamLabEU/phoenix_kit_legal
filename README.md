# PhoenixKit Legal

**Version:** 0.1.0

Standalone legal compliance package for PhoenixKit — GDPR/CCPA legal page generation, cookie consent management, and consent logging.

Extracted from PhoenixKit core as an optional add-on package.

---

## Features

### Legal Pages Generation
- Multi-framework compliance (GDPR, CCPA, LGPD, PIPEDA, etc.)
- Company information management
- DPO (Data Protection Officer) contact
- Automated legal page generation via `phoenix_kit_publishing`
- Page publishing workflow

### Cookie Consent Widget
- Floating consent icon with customizable position
- Full preferences modal with category toggles
- Google Consent Mode v2 integration
- Script blocking by consent category
- Cross-tab synchronization
- Auto-inject via JavaScript (no layout changes required)

---

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit, "~> 1.7"},
    {:phoenix_kit_legal, github: "BeamLabEU/phoenix_kit_legal"}
  ]
end
```

---

## Quick Start

### Enable the Module

```elixir
# Publishing module must be enabled first
PhoenixKit.Modules.Publishing.enable_system()

# Then enable Legal module
PhoenixKit.Modules.Legal.enable_system()
```

### Configure Frameworks

```elixir
# Set compliance frameworks
PhoenixKit.Modules.Legal.set_frameworks(["gdpr", "ccpa"])

# Update company information
PhoenixKit.Modules.Legal.update_company_info(%{
  "name" => "ACME Corp",
  "address_line1" => "123 Main St",
  "city" => "New York",
  "country" => "US",
  "website_url" => "https://acme.com"
})
```

### Generate Legal Pages

```elixir
# Generate all required pages
PhoenixKit.Modules.Legal.generate_all_pages()

# Or generate individual page
PhoenixKit.Modules.Legal.generate_page("privacy-policy")

# Publish a page
PhoenixKit.Modules.Legal.publish_page("privacy-policy")
```

### Enable Cookie Consent Widget

```elixir
# Enable widget
PhoenixKit.Modules.Legal.enable_consent_widget()

# Configure position (bottom-right, bottom-left, top-right, top-left)
PhoenixKit.Modules.Legal.update_icon_position("bottom-right")

# Enable Google Consent Mode v2
PhoenixKit.Modules.Legal.enable_google_consent_mode()
```

---

## Compliance Frameworks

| Framework | Region | Consent Model |
|-----------|--------|---------------|
| GDPR | EU/EEA | Opt-in |
| UK GDPR | UK | Opt-in |
| CCPA/CPRA | California | Opt-out |
| US States | US | Opt-out |
| LGPD | Brazil | Opt-in |
| PIPEDA | Canada | Opt-in |
| Generic | Other | Notice |

---

## Settings Interface

Access at: `/{prefix}/admin/settings/legal`

### Sections

1. **Module Enable/Disable** — Toggle legal module
2. **Compliance Frameworks** — Select active frameworks
3. **Company Information** — Business details for legal pages
4. **DPO Contact** — Data Protection Officer information
5. **Cookie Consent Widget** — Widget configuration
6. **Legal Pages** — Generate and manage pages

---

## Cookie Consent Widget Integration

Add to your root layout (`root.html.heex`):

```heex
<%!-- In your <head> section --%>
<script>
  window.PHOENIX_KIT_PREFIX = "<%= PhoenixKit.Utils.Routes.url_prefix() %>";
</script>

<%!-- Cookie Consent Script (auto-initializes on DOMContentLoaded) --%>
<script defer src={PhoenixKit.Utils.Routes.path("/assets/phoenix_kit_consent.js")}>
</script>
```

---

## Dependencies

- `phoenix_kit` ~> 1.7
- `phoenix_kit_publishing` — Required for page storage
- `phoenix_live_view` ~> 1.0
- `ecto_sql` ~> 3.10
- `gettext` ~> 0.20

---

## License

MIT License. See LICENSE.md.
