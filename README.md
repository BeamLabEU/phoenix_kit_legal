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
    {:phoenix_kit_legal, "~> 0.3"}
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

### Automated setup

Run the install task to patch your app automatically:

```bash
mix phoenix_kit_legal.install
```

This task is **idempotent** — safe to run multiple times. It performs three steps:

| Step | What it does |
|------|--------------|
| `lib/**/endpoint.ex` | Adds `Plug.Static` at `/phoenix_kit_legal` to serve the consent JS |
| `assets/css/app.css` | Adds `@source "../../deps/phoenix_kit_legal"` for Tailwind class scanning |
| `assets/js/app.js` | Adds `import "../../deps/phoenix_kit_legal/priv/static/assets/phoenix_kit_consent.js"` |

Then it prints the remaining manual steps (migration, JS hook, router scope, component).

#### Manual steps after install

**1. Copy and run the migration:**

```bash
cp deps/phoenix_kit_legal/priv/migrations/add_phoenix_kit_consent_logs.exs \
   priv/repo/migrations/$(date +%Y%m%d%H%M%S)_add_phoenix_kit_consent_logs.exs
# Edit: rename MyApp.Repo to your repo module name
mix ecto.migrate
```

**2. Wire up the JS hook in `assets/js/app.js`:**

```js
// Side-effect import — IIFE registers window.PhoenixKitHooks.CookieConsent
import "../../deps/phoenix_kit_legal/priv/static/assets/phoenix_kit_consent.js"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...Hooks, ...window.PhoenixKitHooks },
  params: {_csrf_token: csrfToken}
})
```

**3. Add the router scope in `router.ex`:**

```elixir
scope "/admin/settings", PhoenixKitWeb.Live.Modules.Legal do
  live "/legal", Settings, :index
end
```

**4. Add the CookieConsent component to your root layout:**

```heex
<PhoenixKit.Modules.Legal.CookieConsent.cookie_consent
  frameworks={["gdpr"]}
  phoenix_kit_current_scope={@phoenix_kit_current_scope}
/>
```

Pass `phoenix_kit_current_scope={@phoenix_kit_current_scope}` so the component
can decide server-side whether to render for authenticated users. The assign
is already available in root layouts wired via `PhoenixKitWeb.Integration`.
Omitting it is safe — the widget renders for everyone (same as an anonymous
visitor), but the "Hide for authenticated users" setting will have no effect.

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Enable the module in admin settings (`legal_enabled: true`)
4. Select compliance frameworks (e.g., GDPR, CCPA)
5. Fill in company and DPO contact information
6. Generate legal pages — they appear under `/admin/settings/legal`
7. Publish them — they go live at `/legal/:slug` with no routing work

## Public Legal Pages

**No router changes are needed to serve public legal pages.** The router scope in
[Installation](#installation) is for the *admin settings* screen only.

Legal doesn't render public pages itself. It generates them into a
`phoenix_kit_publishing` group slugged `"legal"`, and Publishing's
`/:language/:group/*path` dispatch serves them like any other group:

| URL | What renders |
|-----|--------------|
| `/legal` | Index of every published legal page |
| `/legal/privacy-policy` | That page |
| `/en/legal/privacy-policy` | Same page, explicit locale prefix |

The division of labour is deliberate — **Legal generates content, Publishing
renders it.** That means legal pages inherit everything Publishing already does:
per-language versions, translation, in-place editing from the admin post editor,
canonical / `og:*` / hreflang tags, and the language switcher. There's no second
rendering path to keep in sync.

Pages are only reachable once **published** — a generated page sits in `draft`
until you publish it, and drafts 404 for anonymous visitors. Check status under
`/admin/settings/legal`, or call `Legal.all_required_pages_published?/0`.

### Linking to legal pages

`get_published_legal_links/0` returns published pages as `%{title:, url:}` maps,
which is what the cookie consent widget uses to build its links:

```elixir
PhoenixKit.Modules.Legal.get_published_legal_links()
#=> [%{title: "Privacy Policy", url: "/legal/privacy-policy"},
#    %{title: "Cookie Policy", url: "/legal/cookie-policy"}]
```

URLs are emitted without a locale prefix so the host app's locale plug resolves
the visitor's current language on click.

### If you want a custom `/legal` page

Declaring a host route at `/legal` is **not** supported — Publishing's dispatch
runs in the router's `call/2` override, so it claims the path before your route
is matched. To customize, either edit the generated posts in the Publishing
editor, or override the EEx templates (see
[Template Customization](#template-customization)).

> **Upgrading from 0.1.6?** That release reserved `/legal` for a host-app LiveView
> this module never shipped, which 404'd public legal pages. 0.1.7 reverts it —
> see [Upgrading](#upgrading).

## Upgrading

```bash
mix deps.update phoenix_kit_legal phoenix_kit_publishing
mix phoenix_kit.update      # apply any pending schema migrations
# restart the app
```

**From 0.1.10 this package requires `phoenix_kit ~> 1.7.227`** (up from `~> 1.7.189`),
because core took over the `/api/consent-config` endpoint — see
[API Endpoint](#api-endpoint). The command above pulls core up with it. If your app
pins core to an older version explicitly, dependency resolution will refuse the
upgrade; raise that pin rather than holding this package back.

Then verify:

```bash
curl -I https://yoursite/legal                  # expect 200
curl -I https://yoursite/legal/privacy-policy   # expect 200
```

### Still 404 after upgrading?

Two causes, in order of likelihood:

1. **Pages are still drafts.** Upgrading publishes nothing. A generated page sits
   in `draft`, and Publishing 404s unpublished posts for anonymous visitors. Open
   `/admin/settings/legal` and publish them, or check
   `Legal.all_required_pages_published?/0`.

   > **On 0.1.8 or earlier, publishing itself was broken.** `publish_page/2` —
   > and the admin "Publish" button that calls it — reported success while
   > leaving the page a draft ([#11](https://github.com/BeamLabEU/phoenix_kit_legal/issues/11)).
   > If a page reads as published but still 404s, upgrade to **0.1.9+** and
   > publish it again.
2. **A leftover `/legal` route from the 0.1.6 workaround.** Delete it. Publishing's
   dispatch rewrites the path in the router's `call/2` before route matching, so
   such a route is unreachable no matter where it sits in `router.ex`.

### What you don't need to do

- **No new migration** is introduced by 0.1.7. The `phoenix_kit_consent_logs`
  schema is unchanged. `mix phoenix_kit.update` is still worth running — it's
  idempotent and picks up core migrations if you're several versions behind.
- **No cache to clear.** Publishing resolves group slugs with a live DB lookup per
  request and recomputes reserved prefixes per call; a normal restart is enough.
- **No config or settings changes**, and no router changes.

If the consent widget renders unstyled, your Tailwind build didn't pick up the
module's CSS sources — run `mix phoenix_kit.assets.rebuild`.

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
| `legal_hide_for_authenticated` | `true` | Hide widget for logged-in users |

## API Endpoint

**`GET /phoenix_kit/api/consent-config`** — Returns widget configuration as JSON.

Used by the client-side consent manager to initialize the widget. Cached
`private, max-age=60` — the payload embeds locale-dependent translations, so it is
cacheable per user but must never be shared. Auth-gating is handled server-side by
the component, not this endpoint.

**The endpoint is owned by `phoenix_kit`, not this package.** Core declares the
route unconditionally and its `PhoenixKitWeb.Controllers.ConsentConfig` answers 204
when this package is absent; when it is installed, that controller delegates to
`Legal.get_consent_widget_config/0` for the payload. This package defined its own
`PhoenixKitWeb.Controllers.ConsentConfigController` through 0.1.9 and no longer
does.

That makes core a hard requirement — hence the `{:phoenix_kit, "~> 1.7.227"}` floor
in `mix.exs`. Core declares the route whenever this module is loaded, so on an older
core the route resolves to a controller that no longer exists anywhere.

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
