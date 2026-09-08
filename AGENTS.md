# AGENTS.md

Guidance for AI agents working on `phoenix_kit_legal`.

## Overview

Legal compliance module for PhoenixKit: it selects compliance frameworks
(GDPR/CCPA/LGPD/PIPEDA and friends), generates legal pages from EEx templates
into the Publishing module, renders the cookie consent widget with Google
Consent Mode v2, and logs consent decisions to an audit trail. It implements the
`PhoenixKit.Module` behaviour and is auto-discovered by the host application.
Legal generates content; Publishing renders it.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex), `phoenix_kit_publishing` `~> 0.5`
  (hard — legal pages are Publishing posts and Publishing serves them publicly;
  call sites still go through `publishing_enabled?/0`, which rescues, and a
  `@compile {:no_warn_undefined, …}` list). Also `phoenix_live_view ~> 1.0`,
  `ecto_sql ~> 3.10`, `gettext ~> 1.0`.
- **Consumed by:** no sibling module. Core reaches into it behind
  `Code.ensure_loaded?(PhoenixKit.Modules.Legal)` from three places: the
  consent-config controller, `AssetsController` (serves this package's
  `phoenix_kit_consent.js`), and `LayoutWrapper` (renders the widget).
- **Admin surface:** one settings subtab, `Settings → Legal`, at
  `{prefix}/admin/settings/legal` (tab id `:admin_settings_legal`, parent
  `:admin_settings`, permission `"legal"`). No public pages of its own.
- **Module key** `"legal"`; settings prefix `legal_`.

## What this module does NOT do

- **No public LiveView, controller or template.** Generated pages are Publishing
  posts in the group slugged `"legal"`; Publishing's `/:language/:group/*path`
  catch-all serves them at `/legal` and `/legal/:slug`, with languages,
  translations, canonical/`og:*`/hreflang, editing and the version dropdown.
  Adding a renderer here duplicates a path Publishing already owns.
- **No `reserved_route_prefixes/0`.** Reserving `"legal"` removes `/legal` from
  Publishing's dispatch while nothing replaces it, so every host that has not
  hand-written a LiveView 404s on its legal pages.
  `test/phoenix_kit_legal/reserved_route_prefixes_test.exs` guards this.
- **No consent-config controller.** `GET /phoenix_kit/api/consent-config` is
  core's route and core's controller; see Feature notes.
- **No migration template under `priv/`.** Hosts migrate through
  `mix phoenix_kit.update`, which discovers the chain and writes the wrapper.
- **No background workers.** Page generation and consent logging are
  synchronous.
- **No second copy of the consent-log column widths.** `ConsentLog.column_widths/0`
  is the only place the numbers exist.

## Commands

```bash
mix deps.get
mix test                     # no database needed; this suite has no Repo and no :integration tag
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`mix precommit` here also runs `deps.unlock --check-unused` and `mix hex.audit`.
`mix quality` (format + credo + dialyzer) and `mix quality.ci`
(format --check-formatted + …) are the two halves it composes.

`phoenix_kit*` deps resolve from Hex and this module does not carry the
`pk_dep/3` helper. To run against a local core checkout, temporarily change the
dep to `{:phoenix_kit, path: "../phoenix_kit", override: true}` in `mix.exs`,
run `mix deps.get`, and revert **both** `mix.exs` and `mix.lock` before
committing (switching between path and Hex resolution rewrites the lock).
`test/core_pin_conformance_test.exs` fails on a committed `path:` override, and
on a three-segment requirement such as `~> 2.0.3` (which admits no 2.1+ core and
breaks consumers, never this repo).

## Conventions

- **Module key** is `"legal"` in every callback. Settings keys are prefixed
  `legal_`. Page slugs and URL segments are hyphenated (`privacy-policy`,
  `do-not-sell`, `cookie-policy`).
- **Never hardcode paths.** Use `PhoenixKit.Utils.Routes.path/1`; there is no
  `Legal.Paths` module. Public legal URLs pass `locale: :none` — Publishing owns
  the language prefix.
- **Routing:** this module registers a settings tab carrying
  `live_view: {PhoenixKitWeb.Live.Modules.Legal.Settings, :index}`. It defines no
  `route_module/0`, no `admin_routes/0`, no `admin_locale_routes/0`, and no
  reserved route prefix. Never hand-register its routes in a host router.
- **LiveView:** `use PhoenixKitWeb, :live_view` (not `use Phoenix.LiveView`),
  followed by `use Gettext, backend: PhoenixKit.Modules.Legal.Gettext` — that
  ordering matters, the second `use` must win. The settings template wraps its
  body in `PhoenixKitWeb.Components.LayoutWrapper.app_layout`. Assigns available
  in admin pages: `@phoenix_kit_current_scope`, `@current_locale`,
  `@current_locale_base`, `@current_path`, `@url_path`, `@project_title`.
- **Gettext:** own backend `PhoenixKit.Modules.Legal.Gettext` over
  `priv/gettext` (`en`, `et`, `ru`, plus `default.pot`). Regenerate with
  `mix gettext.extract --merge priv/gettext`. Strings the extractor cannot see —
  tab labels passed to `Tab.new!(label: …)`, page titles in `@page_types` — are
  seeded by the noop anchor `Legal.__extract_strings__/0`; add new ones there
  before re-extracting, and review every `#, fuzzy` the merge produces.
- **JS:** no `js_sources/0` and no LiveView hooks. `priv/static/assets/phoenix_kit_consent.js`
  is a standalone browser script (banner, preferences modal, localStorage,
  cross-tab sync, Google Consent Mode v2 events) reaching pages two ways: core's
  admin layout emits `<script defer src={Routes.path("/assets/phoenix_kit_consent.js")}>`
  and core's `AssetsController` serves the file out of this package's `priv`; on
  host public pages `mix phoenix_kit_legal.install` adds `Plug.Static` at
  `/phoenix_kit_legal` and an import in `assets/js/app.js`. If a real LiveView
  hook is ever needed it ships through `js_sources/0`, never an inline
  `<script>` — morphdom does not execute inserted script tags, so an inline hook
  vanishes on LiveView navigation.
- **`enabled?/0`** must survive a missing database and return `false`. It reads
  `Settings.get_boolean_setting("legal_enabled", false)`, whose rescue in core
  supplies that; do not replace it with a bare Repo call.
- **Activity/audit threading:** settings writes go through
  `Settings.update_setting_with_module(key, value, "legal")`. Page publishing
  passes `actor_uuid:` — `publish_version/4` audits by that key and ignores the
  `:scope` that `update_post/4` accepts, so a scope passed straight through is
  silently dropped from the audit trail.
- **Consent-log column widths** come from `ConsentLog.column_widths/0` and
  nowhere else: the changeset validations, every producer, and the migration
  chain's DDL all read that map.
- **Count code points, not graphemes,** anywhere a value is bounded against a
  `varchar(n)`. Postgres counts code points; `String.length/1` and
  `validate_length/3` default to graphemes, and they disagree on combining marks
  and ZWJ sequences (20 graphemes of `"é"` is 40 code points). Use
  `count: :codepoints` and `String.codepoints/1`.
- **`css_sources/0`** returns the absolute `@source_root` **only** when the
  `:phoenix_kit_legal` atom entry does not already cover it. Do not simplify it
  back to `[:phoenix_kit_legal, @source_root]`.
- **Consent vocabulary:** types are `"necessary"` (always on), `"analytics"`,
  `"marketing"`, `"preferences"`; modes are `"strict"` (opt-in, the default for
  GDPR) and `"notice"` (opt-out/informational).
- **Publishing must be enabled** before this module can be: `enable_system/0`
  returns `{:error, :publishing_required}` otherwise, and creates the `"legal"`
  group when it succeeds.
- **Soft delete:** none here. Publishing owns trashing of legal pages;
  `diagnose_legal_pages/0` and `reset_legal_pages/0` deal with trashed posts
  whose slugs collide with regeneration.

### Landmines

- The migration chain's destructive-statement guard is a denylist over
  `execute(`: `drop(table(...))`, `drop_if_exists(...)` and `rename(...)` reach
  the database just as directly and leave all eighteen ownership tests green.
  Review chain edits by hand; see
  `dev_docs/reports/2026-08-19-executed-path-guard-allowlist-gap.md`.
- Publishing refuses `status: "published"` through `update_post/4` and still
  returns `{:ok, post}` — page stays a draft, public URL 404s, admin button
  looks like it worked. Publish through `publish_version/4`, which sets status
  and `active_version_uuid` in one transaction.
- The page timestamp is `:content_updated_at` at the **top level** of
  Publishing's post map; `metadata.updated_at` has never existed. Read the wrong
  one and `updated_at` is permanently `nil`, `get_auto_policy_version/0` falls
  back to the manual setting forever, and no visitor is ever re-prompted to
  consent. `test/phoenix_kit_legal/policy_version_test.exs` pins the key against
  Publishing's own mapper.
- An over-long `legal_policy_version` is accepted at the setting and then
  rejects **every** consent write in `ConsentLog.changeset/2` — an audit-trail
  outage far from the change that caused it. `update_policy_version/1` bounds it
  by `ConsentLog.column_widths().consent_version`, and `format_version_date/1`
  falls back to `get_policy_version/0` rather than returning an unparsed
  timestamp verbatim (an offset-less ISO8601 string with microseconds is 26
  characters).
- Returning both `:phoenix_kit_legal` and the absolute source root from
  `css_sources/0` unconditionally writes the same directory twice into the
  host's `assets/css/_phoenix_kit_sources.css`, the second time under a
  build-machine path: core's compiler runs `Enum.uniq/1` on the raw entries (an
  atom and a string, never equal) before formatting them. The absolute entry
  still has to exist for `{:phoenix_kit_legal, path: "…"}` installs, hence the
  condition rather than a deletion; `css_sources_test.exs` guards both
  directions.

## Architecture

```
lib/
├── phoenix_kit_legal.ex                  # OTP-app entry point, version/0
├── mix/tasks/phoenix_kit_legal.install.ex # host patcher (endpoint, app.css, app.js)
└── phoenix_kit_legal/
    ├── legal.ex                          # PhoenixKit.Module facade
    ├── legal_framework.ex                # LegalFramework struct
    ├── page_type.ex                      # PageType struct
    ├── gettext.ex                        # module Gettext backend
    ├── migrations.ex                     # module-owned migration chain
    ├── schemas/consent_log.ex            # consent audit trail schema
    ├── services/template_generator.ex    # EEx rendering
    └── web/
        ├── cookie_consent.ex             # Phoenix.Component (widget)
        └── settings.ex + settings.html.heex  # admin LiveView
priv/
├── gettext/                              # default.pot + en, et, ru
├── legal_templates/*.eex                 # 7 bundled page templates
└── static/assets/phoenix_kit_consent.js  # browser consent manager
```

Key modules:

- **`PhoenixKit.Modules.Legal`** — the facade: behaviour callbacks, framework
  selection, company/DPO info, page generation and publishing, consent widget
  config.
- **`Legal.Migrations`** — the versioned chain (`current_version/0`,
  `migrated_version_runtime/1`, `up/1`, `down/1`, and the testable
  `up_statements/1` / `down_statements/2` builders).
- **`Legal.ConsentLog`** — Ecto schema plus `column_widths/0`, `changeset/2`,
  `create/1`, `log_consents/2`.
- **`Legal.TemplateGenerator`** — EEx rendering with parent-app overrides.
- **`Legal.CookieConsent`** — the glass-morphic widget component.
- **`PhoenixKitWeb.Live.Modules.Legal.Settings`** — the admin LiveView.

### Data model

`phoenix_kit_consent_logs` (UUIDv7 PK) is the only table this module touches;
legal pages live in Publishing's tables.

| Column | Notes |
|---|---|
| `uuid` | UUIDv7 primary key |
| `user_uuid`, `session_id` | identity — at least one is required |
| `consent_type` | `necessary` \| `analytics` \| `marketing` \| `preferences` |
| `consent_given` | boolean, default `false` |
| `consent_version` | policy version at the time of consent |
| `ip_address`, `user_agent_hash` | compliance metadata (SHA256 hash) |
| `metadata` | JSONB, extensible |

`varchar` widths (`session_id` 64, `consent_type` 30, `consent_version` 20,
`ip_address` 45, `user_agent_hash` 64) are declared once in
`ConsentLog.column_widths/0`. Writes go through `ConsentLog.changeset/2`;
`log_consents/2` wraps the whole map in one transaction, so a rejected entry
commits none of the others. A caller already inside a transaction gets no
return value from it — Ecto nests without a savepoint, so the rollback aborts
the outer transaction and `{:error, errors}` surfaces there instead.

### Settings keys

| Key | Meaning |
|---|---|
| `legal_enabled` | module enabled flag |
| `legal_frameworks` | JSON `{"items": ["gdpr", "ccpa"]}` |
| `legal_company_info` | JSON: name, address, country, registration, VAT, website |
| `legal_dpo_contact` | JSON: DPO name, email, phone, address |
| `legal_consent_widget_enabled` | cookie consent widget on/off |
| `legal_consent_mode` | `"strict"` or `"notice"` |
| `legal_cookie_banner_position` | `bottom-left` \| `bottom-right` \| `top-left` \| `top-right` |
| `legal_policy_version` | manual version string (default `"1.0"`) |
| `legal_google_consent_mode` | Google Consent Mode v2 on/off |
| `legal_hide_for_authenticated` | hide the widget for logged-in users |

### Compliance frameworks

| ID | Region | Consent model | Required pages |
|----|--------|---------------|----------------|
| `gdpr` | EU/EEA | opt-in | privacy-policy, cookie-policy |
| `uk_gdpr` | UK | opt-in | privacy-policy, cookie-policy |
| `ccpa` | California | opt-out | privacy-policy, do-not-sell |
| `us_states` | 15+ US states | opt-out | privacy-policy |
| `lgpd` | Brazil | opt-in | privacy-policy |
| `pipeda` | Canada | opt-in | privacy-policy |
| `generic` | Global | notice | privacy-policy |

### Template resolution

Templates live in `priv/legal_templates/`, resolved in this order:

1. parent app's `priv/legal_templates/{name}.{lang}.eex`
2. bundled language-specific template
3. parent app's `priv/legal_templates/{name}.eex`
4. bundled base template

Every template receives `@company_name`, `@company_address`, `@company_country`,
`@company_website`, `@registration_number`, `@vat_number`, `@dpo_name`,
`@dpo_email`, `@dpo_phone`, `@dpo_address`, `@frameworks`, `@effective_date`,
`@language`.

### Public route contract

Generated pages are Publishing posts in the group slugged `"legal"`
(`@legal_blog_slug`). Consequences when changing page-generation code:

- a page is publicly reachable only once its status is `"published"` —
  Publishing 404s drafts for anonymous visitors;
- `get_published_legal_links/0` hardcodes the `/legal/{slug}` URL shape and must
  stay in sync with Publishing's dispatch; the cookie consent widget shows those
  links to every visitor;
- renaming `@legal_blog_slug` changes public URLs and breaks inbound links.

### Permissions

One permission key, `"legal"` (`permission_metadata/0`, icon `hero-scale`),
carried by the settings tab. No sub-permissions.

## Database & migrations

Owns a versioned chain: `PhoenixKit.Modules.Legal.Migrations` via
`migration_module/0`, marker `pkl_schema:<N>` as a COMMENT ON
`phoenix_kit_consent_logs`, currently V1. `mix phoenix_kit.update` applies it in
hosts; this repo's tests never run it (they inspect the statement builders
instead).

The table itself ships in core's V135 baseline, so it exists on every install
with or without this package, and core's `ExpectedSchema` still lists the table,
its 11 columns, 6 indexes and the pkey as `owner: :core`. Both facts hold at
once: **core creates the table and audits its current shape; this chain owns its
future shape.** V1 is an adoption, not a create — `CREATE TABLE IF NOT EXISTS`
with core's exact object names, then the marker — so it changes nothing core's
manifest audits and needed no core release.

Rules:

- **Never edit V1.** A shape change is V2+, and it needs core's generated
  baseline to exclude the altered objects first, or `mix phoenix_kit.doctor` and
  `mix phoenix_kit.repair` will report drift against the V135 shape.
- **`down/1` drops nothing** — it unstamps the marker and stops. The rows are a
  GDPR/CCPA consent audit trail and the table is core-created.
- **The chain never emits `DROP`, `TRUNCATE` or `DELETE`, and never calls Ecto's
  destructive macros** (`drop`, `drop_if_exists`, `rename`,
  `alter … do remove … end`). Test coverage of this rule is partial — see
  Landmines.
- Every varchar width in the DDL is interpolated from
  `ConsentLog.column_widths/0`; never restate a number.
- Every `up/1` statement is idempotent (`IF NOT EXISTS` or a `DO` block), because
  it runs against objects core already created.
- A marker-less table reads as version 0. Prefixes are validated against
  `^[a-zA-Z_][a-zA-Z0-9_]*$` before interpolation into DDL.

UUIDv7 PKs; table-backed schemas `use PhoenixKit.SchemaPrefix`
(`test/schema_prefix_conformance_test.exs` enforces it).

## Testing

`mix test` needs **no database**: there is no test Repo, no `DataCase`, no
`config/` directory, and nothing tagged `:integration`. Tests exercise pure
functions, rendered components and source text. Consequently the migration chain
is verified by parsing `up_statements/1` and `down_statements/2` and by reading
`lib/phoenix_kit_legal/migrations.ex` as text — never by running it.

`test/test_helper.exs`:

- starts `PhoenixKit.Cache.Registry` and the `:settings` cache so Settings-backed
  helpers resolve without Ecto; tests seed values with
  `PhoenixKit.Cache.put(:settings, key, value)`;
- excludes `:requires_phoenix_kit_i18n_api` when
  `PhoenixKit.Dashboard.Tab.localized_label/1` is not exported. Every core the
  current pin admits exports it, so the gate is inert today.

The install task's integration tests are `@moduletag :tmp_dir` and build a
fixture Phoenix tree; they `File.cd!/1` into it, so they are `async: false`.

Test-writing rule this suite has been bitten by twice: **assert that a discovery
found something before asserting the thing it found is clean.** A glob over a
path that does not resolve returns `[]`, and a marker regex that no longer
matches finds no schemas — both leave `offenders == []` and "no stray migration
templates" green while checking nothing. `schema_prefix_conformance_test.exs`
and `consent_logs_ownership_test.exs` assert the discovery first for exactly
this reason. The mirror of it: do not add a guard on an unreachable state, which
reads as protection and can never go red.

## Feature notes

| Feature | Constraint | Guide |
|---|---|---|
| Consent-log ownership | Core creates and audits `phoenix_kit_consent_logs`; this package owns its future shape through the chain. V1 must stay shape-identical to core's baseline, and a V2+ shape change needs core's excluded-object list updated first. | `dev_docs/guides/consent-logs-ownership.md` |
| Consent config endpoint | `GET /phoenix_kit/api/consent-config` is core's route and core's controller. Never define a consent-config controller here; core ≥ 1.7.227 is the true floor (the `~> 2.0` pin satisfies it for unrelated reasons). | `dev_docs/guides/consent-logs-ownership.md` |

Root-cause records for the two public-page outages this module has had live in
`dev_docs/reports/2026-07-25-legal-public-pages-404.md` (route reservation with
no renderer) and `dev_docs/reports/2026-07-25-publish-page-silent-noop.md`
(publishing through `update_post/4`).

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- The executed-path guard in `consent_logs_ownership_test.exs` is a denylist over
  `execute(` and misses Ecto's other destructive macros. Closing it means
  asserting an allowlist over what the chain actually executes, which is a design
  decision, not a patch; the reasoning and the options are in
  `dev_docs/reports/2026-08-19-executed-path-guard-allowlist-gap.md`. Unblocked
  when someone picks the allowlist shape.
- `test_helper.exs` still gates `:requires_phoenix_kit_i18n_api` on
  `Tab.localized_label/1` being exported. Every core the `~> 2.0` pin admits
  exports it, so the gate can be deleted the next time this file is touched for
  another reason.
