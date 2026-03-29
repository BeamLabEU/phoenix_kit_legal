# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Legal — a legal compliance module for the PhoenixKit framework providing GDPR/CCPA/LGPD/PIPEDA compliant legal page generation, a cookie consent widget with Google Consent Mode v2, and consent audit logging. Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application. Legal pages are stored via the Publishing module.

## Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests
mix test test/file_test.exs # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix docs                    # Generate documentation
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Architecture

This is a **library** (not a standalone Phoenix app) that provides legal compliance as a PhoenixKit plugin module.

### Key Modules

- **`PhoenixKit.Modules.Legal`** (`lib/phoenix_kit_legal/legal.ex`) — Main facade implementing `PhoenixKit.Module` behaviour. Framework selection, page generation, consent widget configuration, company/DPO info management.

- **`Legal.LegalFramework`** (`lib/phoenix_kit_legal/legal_framework.ex`) — Struct representing a compliance framework (id, name, regions, consent model, required/optional pages).

- **`Legal.PageType`** (`lib/phoenix_kit_legal/page_type.ex`) — Struct for a legal page type (slug, title, template filename, description).

- **`Legal.ConsentLog`** (`lib/phoenix_kit_legal/schemas/consent_log.ex`) — Ecto schema for consent audit trail. Tracks user/session consent decisions with timestamps, IP, and hashed user agent.

- **`Legal.TemplateGenerator`** (`lib/phoenix_kit_legal/services/template_generator.ex`) — Renders legal pages from EEx templates with company/DPO context. Supports language-specific templates and parent app overrides.

- **`Legal.Web.ConsentConfigController`** (`lib/phoenix_kit_legal/web/consent_config_controller.ex`) — JSON API endpoint for cookie consent widget configuration. Serves at `/phoenix_kit/api/consent-config`.

- **`Legal.Web.CookieConsent`** (`lib/phoenix_kit_legal/web/cookie_consent.ex`) — Phoenix component rendering the glass-morphic cookie consent widget UI.

- **`Legal.Web.Settings`** (`lib/phoenix_kit_legal/web/settings.ex`) — Admin LiveView for all legal module configuration (frameworks, company info, DPO, page generation, consent widget settings).

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `settings_tabs/0` callback registers the admin settings page
4. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
5. Legal pages are generated from EEx templates and stored via the Publishing module as posts
6. Cookie consent widget is injected client-side via `phoenix_kit_consent.js`
7. Consent decisions are logged to `phoenix_kit_consent_logs` for GDPR audit compliance

### Compliance Frameworks (7 total)

| ID | Region | Consent Model | Required Pages |
|----|--------|---------------|----------------|
| `gdpr` | EU/EEA | opt-in | privacy-policy, cookie-policy |
| `uk_gdpr` | UK | opt-in | privacy-policy, cookie-policy |
| `ccpa` | California | opt-out | privacy-policy, do-not-sell |
| `us_states` | 15+ US states | opt-out | privacy-policy |
| `lgpd` | Brazil | opt-in | privacy-policy |
| `pipeda` | Canada | opt-in | privacy-policy |
| `generic` | Global | notice | privacy-policy |

### Database Table

**`phoenix_kit_consent_logs`** — Consent audit trail (UUIDv7 PK)

- `uuid` (UUIDv7), `user_uuid` (optional), `session_id` (optional) — identity
- `consent_type` — "necessary", "analytics", "marketing", or "preferences"
- `consent_given` — boolean
- `consent_version` — policy version string at time of consent
- `ip_address`, `user_agent_hash` (SHA256) — compliance metadata
- `metadata` JSONB — extensible additional data
- Requires either `user_uuid` or `session_id` (at least one)

This is the only database table. Legal pages are stored in the Publishing module's tables.

### Template System

Templates live in `priv/legal_templates/`. Resolution order:
1. Parent app's `priv/legal_templates/{name}.{lang}.eex` (language-specific override)
2. Bundled language-specific template
3. Parent app's `priv/legal_templates/{name}.eex` (base override)
4. Bundled base template

All templates receive `@company_name`, `@company_address`, `@company_country`, `@company_website`, `@registration_number`, `@vat_number`, `@dpo_name`, `@dpo_email`, `@dpo_phone`, `@dpo_address`, `@frameworks`, `@effective_date`, `@language`.

### Client-Side Assets

- **`priv/static/assets/phoenix_kit_consent.js`** — Cookie consent manager. Handles banner display, preference modal, localStorage persistence, cross-tab sync, and Google Consent Mode v2 events.

### File Layout

```
lib/
├── phoenix_kit_legal/
│   ├── phoenix_kit_legal.ex          # Entry point, version info
│   ├── legal.ex                      # Main module (PhoenixKit.Module behaviour)
│   ├── legal_framework.ex            # LegalFramework struct
│   ├── page_type.ex                  # PageType struct
│   ├── schemas/
│   │   └── consent_log.ex            # Consent audit trail schema
│   ├── services/
│   │   └── template_generator.ex     # EEx template rendering
│   └── web/
│       ├── consent_config_controller.ex  # JSON API for widget config
│       ├── cookie_consent.ex         # Phoenix component (consent widget)
│       └── settings.ex               # Admin settings LiveView
priv/
├── legal_templates/                  # Bundled EEx templates (7 pages)
│   ├── privacy_policy.eex
│   ├── cookie_policy.eex
│   ├── terms_of_service.eex
│   ├── do_not_sell.eex
│   ├── data_retention_policy.eex
│   ├── ccpa_notice.eex
│   └── acceptable_use.eex
└── static/assets/
    └── phoenix_kit_consent.js        # Client-side consent manager
```

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"legal"`
- **Settings keys** are prefixed with `legal_` (e.g., `legal_enabled`, `legal_consent_mode`)
- **Publishing dependency** — legal pages are stored as Publishing posts. The Publishing module must be available for page generation to work.
- **`enabled?/0`** must rescue errors and return `false` as fallback (DB may not be available)
- **LiveViews use `PhoenixKitWeb` macros** — use `use PhoenixKitWeb, :live_view` (not `use Phoenix.LiveView` directly)
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **No background workers** — all operations are synchronous (page generation, consent logging)
- **Consent types**: "necessary" (always on), "analytics", "marketing", "preferences"
- **Consent modes**: "strict" (opt-in, default for GDPR) or "notice" (opt-out/informational)

## Settings Keys

All stored via PhoenixKit Settings:

- `legal_enabled` — module enabled flag
- `legal_frameworks` — JSON `{"items": ["gdpr", "ccpa"]}` — selected frameworks
- `legal_company_info` — JSON with company details (name, address, registration, VAT)
- `legal_dpo_contact` — JSON with DPO details (name, email, phone, address)
- `legal_consent_widget_enabled` — cookie consent widget enabled
- `legal_consent_mode` — "strict" or "notice"
- `legal_cookie_banner_position` — icon position ("bottom-left", "bottom-right", "top-left", "top-right")
- `legal_policy_version` — manual version string (default: "1.0")
- `legal_google_consent_mode` — Google Consent Mode v2 enabled
- `legal_hide_for_authenticated` — hide widget for logged-in users

## Versioning & Releases

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-27" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs` and the version function in the main module
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`).

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper
- **PhoenixKit Publishing** — Legal page storage as posts (via Publishing module's tables)
- **Phoenix LiveView** (`~> 1.0`) — Admin settings LiveView
- **Ecto SQL** (`~> 3.10`) — Consent log schema
- **Gettext** (`~> 1.0`) — Template internationalization
