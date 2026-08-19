# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## ⚠️ This module owns the shape of one core-created table

`phoenix_kit_consent_logs` is created by core's migration chain (V43, now folded
into the squashed V135 baseline), so it exists on every PhoenixKit install, with or
without this package. Core 2.0's `PhoenixKit.Migrations.ExpectedSchema` still names
the table, all 11 columns, 6 indexes and the pkey as core-owned, and that manifest
is what `mix phoenix_kit.doctor` and `mix phoenix_kit.repair` verify live databases
against.

Since 0.4.0 this package owns the table's **future** shape, through
`PhoenixKit.Modules.Legal.Migrations` — returned by `migration_module/0`
(`legal.ex:871`). V1 of that chain is an *adoption*, not a create: `CREATE TABLE IF
NOT EXISTS` with core's exact object names, then a `pkl_schema:1` comment marker. It
changes no shape, which is why core's manifest stays accurate and no core release
was required. Rationale and the per-audience upgrade paths:
`dev_docs/reports/2026-08-10-consent-logs-extraction.md`.

What the chain must never do — pinned by `test/consent_logs_ownership_test.exs`, to the degree each bullet says:

- **Never restate a column width.** Every varchar width in the DDL is interpolated
  from `ConsentLog.column_widths/0`, this package's single width authority. Three
  separate DDLs for this one table had accumulated by 2026-08-10 — core's, a
  coordinator here, and a copy-into-your-app template the README pointed at — all
  disagreeing on widths and index names
  (`dev_docs/reports/2026-08-10-module-migration-versioning.md`). A second copy of
  those numbers is how that happened.
- **Never ship a migration template under `priv/`.** Hosts migrate through
  `mix phoenix_kit.update`, which discovers the chain and writes the wrapper itself.
- **Never emit `DROP`, `TRUNCATE` or `DELETE`, and never call any of Ecto's
  other destructive macros** (`drop`, `drop_if_exists`, `rename`, `alter ... do
  remove ... end`) **either.** The rows are a GDPR/CCPA consent audit trail, and
  on every current install the table is core-created; `down/1` unstamps the
  marker and does nothing else.
  **The test suite's coverage of this rule is partial**, not the airtight
  guarantee the line above might suggest: `neither direction executes SQL of its
  own` catches a literal `execute("DROP TABLE ...")` written past the builder,
  but not `drop(table(...))`, `drop_if_exists(...)` or `rename(...)` — all
  reach the database exactly as directly and none touch `execute(`, which is
  the only thing that test's regex looks for. Verified, not assumed:
  `dev_docs/reports/2026-08-19-executed-path-guard-allowlist-gap.md` reproduces
  all three against a clean `main`, each leaving all eighteen tests in
  `consent_logs_ownership_test.exs` green. Closing it needs an allowlist over
  what is actually executed, not another denylist entry — that report has the
  reasoning and what it would take.

Changing the table's shape is a chain version (V2+), and it is **not** a
free-standing change: it must follow the excluded-object protocol in the extraction
report, because core's manifest audits the V135 shape until core's generated
baseline excludes the altered objects. A width change that skips that step should
fail review.

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

- **`Legal.Web.CookieConsent`** (`lib/phoenix_kit_legal/web/cookie_consent.ex`) — Phoenix component rendering the glass-morphic cookie consent widget UI.

- **`Legal.Web.Settings`** (`lib/phoenix_kit_legal/web/settings.ex`) — Admin LiveView for all legal module configuration (frameworks, company info, DPO, page generation, consent widget settings).

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `settings_tabs/0` callback registers the admin settings page
4. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
5. Legal pages are generated from EEx templates and stored via the Publishing module as posts
6. **Publishing serves those pages publicly** at `/legal` and `/legal/:slug` — see "Public Route Contract" below
7. Cookie consent widget is injected client-side via `phoenix_kit_consent.js`
8. Consent decisions are logged to `phoenix_kit_consent_logs` for GDPR audit compliance

### Public Route Contract

**This module renders no public pages.** It generates content into the Publishing
group slugged `"legal"` (`@legal_blog_slug`, `legal.ex:63`); Publishing's
`/:language/:group/*path` catch-all dispatch serves it at `/legal` (index) and
`/legal/:slug`. The host app needs no route — the only router scope in the README
is for the admin settings LiveView.

Division of labour: **Legal generates content, Publishing renders it.** Legal has
no public LiveView, controller, or template, and adding one would duplicate a
rendering path Publishing already owns (languages, translations, canonical/`og:*`/
hreflang, editing, version dropdown).

**Do not implement `reserved_route_prefixes/0` in this module.** 0.1.6 did — it
returned `["legal"]` to hand the route to a host-app LiveView that this module
never shipped and never generated, so public legal pages 404'd on every host that
hadn't hand-written one. Reverted in 0.1.7; `test/phoenix_kit_legal/reserved_route_prefixes_test.exs`
guards against reintroducing it. The SEO defect that motivated it (pages
canonicalizing to `"/"`) was fixed at its source by the `assign_url_path` plug in
`phoenix_kit_publishing` 0.2.3.

Consequences to keep in mind when changing page-generation code:

- A page is only publicly reachable once its status is `"published"` — Publishing
  404s drafts for anonymous visitors (`web/controller/post_rendering.ex:60`)
- `get_published_legal_links/0` (`legal.ex:658`) hardcodes the `/legal/{slug}` URL
  shape; it must stay in sync with Publishing's dispatch, and the cookie consent
  widget shows those links to every visitor
- Renaming `@legal_blog_slug` changes public URLs and breaks existing inbound links
- `list_generated_pages/0` reads the page timestamp from Publishing's
  **top-level** `:content_updated_at`, not from `:metadata`. Publishing's
  `:metadata` map has never had an `:updated_at` key, and reading only that key
  made the field permanently `nil` — with it `get_auto_policy_version/0`
  permanently returned the manual setting, so editing a policy page never bumped
  the consent version and no visitor was ever re-prompted. `test/phoenix_kit_legal/policy_version_test.exs`
  asserts the key against Publishing's own mapper

### Policy Version Contract

`get_auto_policy_version/0` → `get_consent_widget_config/0` → the widget →
`phoenix_kit_consent_logs.consent_version`, core's `varchar(20)`. Every producer
on that chain is bounded by `ConsentLog.column_widths/0`, and an unbounded value
anywhere on it is an audit-trail outage: the setting is accepted, and every
consent write afterwards fails validation, far from the change that caused it.

Count **code points**, not `String.length/1`'s graphemes — that is the unit
Postgres counts for `varchar(n)`, and the two differ on combining marks and ZWJ
sequences (20 graphemes of `"é"` is 40 code points). This applies equally to
`validate_length/3`, whose default is graphemes; `validate_column_widths/1`
passes `count: :codepoints`.

`format_version_date/1` falls back to `get_policy_version/0` on an unparseable
timestamp rather than returning it verbatim — an offset-less ISO8601 string with
microseconds is 26 characters.

### Consent Config Endpoint Contract

`GET /phoenix_kit/api/consent-config` is **owned by core**, not by this package.
Since `phoenix_kit` 1.7.227 core declares the route unconditionally and its
`PhoenixKitWeb.Controllers.ConsentConfig` answers 204 when this package is absent,
or delegates to `Legal.get_consent_widget_config/0` when it is present.

**Do not define a consent-config controller here.** This package defined
`PhoenixKitWeb.Controllers.ConsentConfigController` through 0.1.9; PR #12 removed
it for 0.1.10. Core deliberately did *not* reuse that name — a host resolving new
core against legal ≤ 0.1.9 would otherwise have one module compiled into two
applications, with code-path order deciding which answers. Reintroducing either
name here re-creates that hazard.

The corollary is a release-ordering rule: deleting the controller makes core's
version a *hard* requirement, because core declares the route whenever
`PhoenixKit.Modules.Legal` is loaded. On any core before 1.7.227 that route still
points at `…ConsentConfigController` — the module this package used to own — so
every request raises `UndefinedFunctionError`, a 500 per page load, since core's
bundled `phoenix_kit.js` fetches the endpoint on `DOMContentLoaded` whenever the
widget root was not server-rendered. Nothing catches it at compile time: Phoenix
compiles routes to literal tuples, so a missing controller produces no warning.
Hence `{:phoenix_kit, "~> 1.7.227"}` in `mix.exs` — floored in the same release
that shipped the deletion, and it must stay floored.

### Tailwind `css_sources/0` Contract

`css_sources/0` (`legal.ex`) returns the absolute `@source_root` **only** when
the `:phoenix_kit_legal` atom entry doesn't already cover it. Do not simplify it
back to `[:phoenix_kit_legal, @source_root]`.

`Mix.Tasks.Compile.PhoenixKitCssSources` in core calls `Enum.uniq/1` on the raw
callback results — an atom and a path string, never equal — and formats them
into `@source` lines afterwards, so returning both unconditionally wrote the
same directory twice into the host's `assets/css/_phoenix_kit_sources.css`, once
relative and once as a build-machine absolute path. Legal was the only module
returning an absolute root; Publishing and AI return just the atom.

The absolute entry still has to exist for `{:phoenix_kit_legal, path: "..."}`
installs, where `../../deps/phoenix_kit_legal` doesn't resolve — hence the
condition rather than a deletion. `test/phoenix_kit_legal/css_sources_test.exs`
guards both directions.

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

**`phoenix_kit_consent_logs`** — consent audit trail (UUIDv7 PK). **Core's table, not
this package's** — see the warning at the top of this file. This package reads and
writes it and ships no DDL for it; the only table it touches, and it owns none.
Legal pages are stored in the Publishing module's tables.

- `uuid` (UUIDv7), `user_uuid` (optional), `session_id` (optional) — identity
- `consent_type` — "necessary", "analytics", "marketing", or "preferences"
- `consent_given` — boolean
- `consent_version` — policy version string at time of consent
- `ip_address`, `user_agent_hash` (SHA256) — compliance metadata
- `metadata` JSONB — extensible additional data
- Requires either `user_uuid` or `session_id` (at least one)

Core's `varchar` widths are declared once, in `ConsentLog.column_widths/0` (the
numbers are listed in the warning at the top of this file). The changeset derives
its length validations from that map and `Legal.update_policy_version/1` reads its
limit from it — anything else that produces a value for one of these columns
should read it too rather than restating the number. `test/consent_logs_ownership_test.exs`
checks the map against core's `ExpectedSchema`, so a core change surfaces as a
failing test rather than as silent drift.

Writes go through `ConsentLog.changeset/2`; `log_consents/2` wraps the whole map in
one transaction, so a rejected entry commits none of the others.

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
