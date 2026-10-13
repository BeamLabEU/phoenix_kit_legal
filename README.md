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

**1. Apply the schema:**

```bash
mix phoenix_kit.update
```

`phoenix_kit_consent_logs` is a **core** table — it is created by PhoenixKit's own
migration chain (core V43, now folded into the squashed V135 baseline), not by this
package. It exists on every PhoenixKit install, with or without this module, so
`mix phoenix_kit.update` is all that is needed and is safe to re-run.

> **Removed in 0.3.1:** earlier READMEs told you to copy
> `priv/migrations/add_phoenix_kit_consent_logs.exs` into your app and run
> `mix ecto.migrate`. **Do not do that** — that template used `create table`
> (no `if_not_exists`), so on any install where core had already created the
> table it failed outright with "table phoenix_kit_consent_logs already exists".
> It also declared every string column as the Ecto default `varchar(255)`, where
> core uses `varchar(64)`/`(30)`/`(20)`/`(45)`/`(64)`. The template has been
> deleted. If you previously ran it and it succeeded, see
> `dev_docs/reports/2026-08-10-module-migration-versioning.md`.

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
- Automatic DOM injection (no layout changes required) — the script ships in the host's `phoenix_kit_modules.js` via `js_sources/0`
- Authentication-aware display (optional hide for logged-in users)
- A server-side record of each decision: a signed first-party cookie and an audit log entry
- Each category's toggle lists what it covers on this site, as the site's modules declare it

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
| `@data_collection` | What the site's modules declare they collect, grouped by consent category (see below) |

`@data_collection` is a map with the four keys `"necessary"`, `"analytics"`,
`"marketing"` and `"preferences"`, each a list of entries (`title`,
`description`, `data`, `retention`, `basis`, `storage`). The bundled Cookie
Policy is written from it; a custom template can ignore it.

## Consent: the server's record

The banner keeps a visitor's decision in `localStorage`, which a server cannot
read. So each decision is also reported to the server, which does two things
with it:

- **Sets a cookie**, `pk_consent`: the decision as JSON, signed with a key
  derived from the endpoint's `secret_key_base`. A visitor (and the page's
  scripts) can read it; nobody can forge one the server will believe. It
  carries no identity — a random consent ID, the policy version, the
  categories, and when the decision was made.
- **Writes the audit log**: one `phoenix_kit_consent_logs` row per category,
  keyed by the consent ID, with the signed-in user's UUID when there is one.
  The visitor's IP address and a hash of their User-Agent are added only when
  the two settings below ask for them.

Server-side code asks before it collects:

```elixir
alias PhoenixKit.Modules.Legal.Consent

Consent.status(conn, "analytics")   # :granted | :denied | :unknown
Consent.objected?(conn)             # true when the browser sends Sec-GPC: 1
Consent.read(conn)                  # {:ok, %Consent{}} | :none
```

All three read only the request — no database query — so they are safe on a
hot path. An unsigned, tampered or expired cookie is `:unknown`.

A decision lasts `legal_consent_cookie_days` (180 by default), after which the
visitor is asked again. Taking a consent back reloads the page by default, so
a script that already ran does not keep running and the page is served under
the new choice.

The log can also be written directly:

```elixir
alias PhoenixKit.Modules.Legal.ConsentLog

ConsentLog.log_consents(
  %{"analytics" => true, "marketing" => false},
  user_uuid: user.uuid,
  consent_version: "2026-03-27"
)

ConsentLog.get_consent_status(user_uuid: user.uuid)
# => %{"analytics" => true, "marketing" => false}
```

## What the site collects

A cookie policy that lists `_ga` on a site that has never loaded Google
Analytics is as wrong as one that leaves out what the site does collect. So
the list is not written by hand. Any PhoenixKit module that collects something
exports `data_collection/0`:

```elixir
def data_collection do
  [
    %{
      key: "web_analytics.measurement",
      title: "Visit statistics",
      description: "Counts visits to our pages.",
      category: "analytics",          # necessary | analytics | marketing | preferences
      mode: :consent,                 # :always | :consent | :unless_objected | :off
      active: true,
      data: ["The pages you view", "Your country"],
      retention: "365 days",
      storage: [%{name: "cart", kind: "cookie", duration: "30 days", purpose: "Basket"}]
    }
  ]
end
```

It is found by name, so the declaring module needs no dependency on this
package. **Settings → Legal → What this site collects** shows every
declaration with how it is currently collected. Ticked entries are named under
the matching toggle of the banner's preferences dialog and written into the
generated Cookie Policy; unticking one takes it out of both, and the page says
so beside it when the entry is still being collected. The page also says when
the list has changed since the Cookie Policy was generated.

This module declares itself: the `pk_consent` cookie and the consent log.

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
| `legal_consent_log_enabled` | `true` | Write each decision to the consent log |
| `legal_consent_log_ip` | `false` | Keep the visitor's IP address with a log entry |
| `legal_consent_log_user_agent` | `false` | Keep a hash of the User-Agent with a log entry |
| `legal_consent_cookie_days` | `180` | Days a decision lasts before the visitor is asked again (1–730) |
| `legal_consent_reload_on_withdrawal` | `true` | Reload the page when a visitor takes a consent back |
| `legal_hidden_collection` | `[]` | Declared entries the operator took out of the banner and the policy |

## API Endpoints

**`/phoenix_kit/api/consent`** — the visitor's decision. This package's own
route (`PhoenixKit.Modules.Legal.Routes`), spliced in by `phoenix_kit_routes()`.

| Method | Does |
|---|---|
| `GET` | Returns the decision the server holds for this browser (`{"decided": false}` without one) |
| `POST` | Records `{"consent": {"analytics": true, …}, "source": "banner"}`, writes the log and sets the cookie |
| `DELETE` | Logs every category as refused and removes the cookie, so the visitor is asked again |

It is public — a visitor decides before signing in — and carries no CSRF
token, since the banner may run on a cached page. A write is accepted only
from the site itself (`Origin`, else `Sec-Fetch-Site`), takes nothing from the
body but booleans for the known categories, is not logged twice for the same
decision, and is rate-limited per address. It answers 404 while the module or
the banner is off.


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
