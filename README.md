# PhoenixKitLegal

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

Legal compliance module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit). GDPR, CCPA, LGPD, and PIPEDA compliant legal page generation, cookie consent widget, and consent audit logging.

## Features

- **7 compliance frameworks** — GDPR (EU/EEA), UK GDPR, CCPA/CPRA (California), US States (15+), LGPD (Brazil), PIPEDA (Canada), Generic
- **Legal page generation** — Privacy Policy, Cookie Policy, Terms of Service, Do Not Sell, Data Retention, CCPA Notice, Acceptable Use
- **EEx template system** — customizable templates with language support and template override from parent app
- **Cookie consent widget** — glass-morphic UI with floating icon, preferences modal, and consent banner
- **Google Consent Mode v2** — built-in integration for analytics/marketing consent signals
- **Consent audit logging** — full audit trail with user/session tracking, IP, and hashed user agent
- **Publishing integration** — legal pages stored as posts via PhoenixKit Publishing for versioning and multi-language support
- **Admin settings UI** — framework selection, company/DPO info, page generation, widget configuration
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config

## Installation

Add `phoenix_kit_legal` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_legal, "~> 0.1"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

> **Note:** For development or if not yet published to Hex, you can use:
> ```elixir
> {:phoenix_kit_legal, github: "BeamLabEU/phoenix_kit_legal"}
> ```

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Enable the module in admin settings (`legal_enabled: true`)
4. Select compliance frameworks (e.g., GDPR, CCPA)
5. Fill in company and DPO contact information
6. Generate legal pages — they appear under `/admin/settings/legal`

## Compliance Frameworks

| Framework | Region | Consent Model | Required Pages |
|-----------|--------|---------------|----------------|
| GDPR | EU/EEA | Opt-in | Privacy Policy, Cookie Policy |
| UK GDPR | UK | Opt-in | Privacy Policy, Cookie Policy |
| CCPA/CPRA | California | Opt-out | Privacy Policy, Do Not Sell |
| US States | 15+ US states | Opt-out | Privacy Policy |
| LGPD | Brazil | Opt-in | Privacy Policy |
| PIPEDA | Canada | Opt-in | Privacy Policy |
| Generic | Global | Notice | Privacy Policy |

## Page Types

| Page | Template | Description |
|------|----------|-------------|
| Privacy Policy | `privacy_policy.eex` | Data collection, processing, and rights |
| Cookie Policy | `cookie_policy.eex` | Cookie usage and management |
| Terms of Service | `terms_of_service.eex` | Service terms and conditions |
| Do Not Sell | `do_not_sell.eex` | CCPA opt-out for data sales |
| Data Retention | `data_retention_policy.eex` | Data retention periods and policies |
| CCPA Notice | `ccpa_notice.eex` | California-specific privacy notice |
| Acceptable Use | `acceptable_use.eex` | Acceptable use policy |

## Cookie Consent Widget

The consent widget provides a glass-morphic UI with:

- Floating icon (configurable position: bottom-left, bottom-right, top-left, top-right)
- Consent banner for first-time visitors
- Preferences modal with 4 consent categories (necessary, analytics, marketing, preferences)
- Dark mode support via daisyUI CSS variables
- ARIA-compliant accessibility
- localStorage persistence with cross-tab sync
- Automatic DOM injection (no layout changes required)
- Authentication-aware display (optional hide for logged-in users)

### Google Consent Mode v2

When enabled, the widget fires `consent` events for Google Tag Manager:

```javascript
// Default (denied)
gtag('consent', 'default', { analytics_storage: 'denied', ad_storage: 'denied' });

// After user grants analytics
gtag('consent', 'update', { analytics_storage: 'granted' });
```

## Template Customization

Override bundled templates by placing files in your parent app's `priv/legal_templates/`:

```
priv/legal_templates/
  privacy_policy.eex        # Base template override
  privacy_policy.de.eex     # German-specific override
  cookie_policy.eex         # Base template override
```

Template resolution order:
1. Parent app language-specific: `priv/legal_templates/{name}.{lang}.eex`
2. Bundled language-specific template
3. Parent app base: `priv/legal_templates/{name}.eex`
4. Bundled base template

### Template Variables

All templates receive:

| Variable | Description |
|----------|-------------|
| `@company_name` | Company legal name |
| `@company_address` | Company registered address |
| `@company_country` | Company country |
| `@company_website` | Company website URL |
| `@registration_number` | Company registration number |
| `@vat_number` | VAT/tax ID number |
| `@dpo_name` | Data Protection Officer name |
| `@dpo_email` | DPO email address |
| `@dpo_phone` | DPO phone number |
| `@dpo_address` | DPO postal address |
| `@frameworks` | List of selected framework IDs |
| `@effective_date` | Current date (ISO format) |
| `@language` | Language code |

## Consent Logging

Full audit trail for GDPR compliance:

```elixir
alias PhoenixKit.Modules.Legal.ConsentLog

# Log consent for a user
ConsentLog.log_consents(
  %{"analytics" => true, "marketing" => false},
  user_uuid: user.uuid,
  consent_version: "2026-03-27",
  ip_address: "192.168.1.1",
  user_agent: "Mozilla/5.0..."
)

# Check current consent status
ConsentLog.get_consent_status(user_uuid: user.uuid)
# => %{"analytics" => true, "marketing" => false, "necessary" => true}
```

## Architecture

```
lib/phoenix_kit_legal/
  phoenix_kit_legal.ex          # Entry point, version info
  legal.ex                      # Main module (PhoenixKit.Module behaviour)
  legal_framework.ex            # LegalFramework struct
  page_type.ex                  # PageType struct
  schemas/
    consent_log.ex              # Consent audit trail schema
  services/
    template_generator.ex       # EEx template rendering
  web/
    consent_config_controller.ex  # JSON API for widget config
    cookie_consent.ex           # Phoenix component (consent widget)
    settings.ex                 # Admin settings LiveView
priv/
  legal_templates/              # Bundled EEx templates (7 pages)
  static/assets/
    phoenix_kit_consent.js      # Client-side consent manager
```

### Database Table

**`phoenix_kit_consent_logs`** — Consent audit trail (UUIDv7 PK)

| Column | Type | Purpose |
|--------|------|---------|
| `uuid` | UUIDv7 | Primary key |
| `user_uuid` | UUIDv7 | Logged-in user (optional) |
| `session_id` | string | Anonymous session (optional) |
| `consent_type` | string | "necessary", "analytics", "marketing", "preferences" |
| `consent_given` | boolean | Whether consent was granted |
| `consent_version` | string | Policy version at time of consent |
| `ip_address` | string | IP when consent recorded |
| `user_agent_hash` | string | SHA256 hash of user agent |
| `metadata` | JSONB | Additional metadata |

Requires either `user_uuid` or `session_id` (at least one must be present).

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers the module (zero config)
3. `settings_tabs/0` registers the admin settings page
4. Legal pages are generated from EEx templates and stored via the Publishing module
5. Cookie consent widget is injected client-side via JavaScript
6. Consent decisions are logged to `phoenix_kit_consent_logs` for audit compliance

## Settings

| Key | Default | Description |
|-----|---------|-------------|
| `legal_enabled` | `false` | Enable/disable module |
| `legal_frameworks` | `[]` | Selected compliance frameworks |
| `legal_company_info` | `{}` | Company details (name, address, etc.) |
| `legal_dpo_contact` | `{}` | DPO contact details |
| `legal_consent_widget_enabled` | `false` | Enable cookie consent widget |
| `legal_consent_mode` | `"strict"` | Consent mode: "strict" (opt-in) or "notice" |
| `legal_cookie_banner_position` | `"bottom-right"` | Widget icon position |
| `legal_policy_version` | `"1.0"` | Manual policy version string |
| `legal_google_consent_mode` | `false` | Enable Google Consent Mode v2 |
| `legal_hide_for_authenticated` | `false` | Hide widget for logged-in users |

## API Endpoint

**`GET /phoenix_kit/api/consent-config`** — Returns widget configuration as JSON.

Used by the client-side consent manager to initialize the widget. Cached publicly (60s) unless `hide_for_authenticated` is enabled.

## Development

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo --strict # Static analysis (strict mode)
mix dialyzer       # Type checking
mix docs           # Generate documentation
mix precommit      # Compile + format + credo + dialyzer
mix quality        # Format + credo + dialyzer
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `phoenix_kit` | Module behaviour, Settings API, core infrastructure |
| `phoenix_kit_publishing` | Legal page storage as posts |
| `phoenix_live_view` | Admin settings LiveView |
| `ecto_sql` | Consent log schema |
| `gettext` | Template internationalization |

## License

MIT — see [LICENSE.md](LICENSE.md) for details.
