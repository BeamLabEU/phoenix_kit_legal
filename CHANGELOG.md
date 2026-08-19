# Changelog

## 0.4.2 - 2026-08-18

### Fixed

- **daisyUI 5 form classes that styled nothing.** The DPO contact form in the
  admin settings page (`web/settings.html.heex`) still used daisyUI 4's
  `form-control` / `input-bordered` / `label-text` / `label-text-alt`, which v5
  dropped — the classes did nothing and the fields lost their intended
  spacing/border styling. Replaced with v5's `fieldset` / `input` /
  `fieldset-legend` / `fieldset-label`.

### Changed

- Dependency updates: `phoenix_kit` 2.13.1, `phoenix_kit_publishing` 0.7.0, and
  the transitive set they pull.
- Hardened `test/consent_logs_ownership_test.exs`,
  `test/schema_prefix_conformance_test.exs`, and
  `test/phoenix_kit_legal/i18n_test.exs` against vacuous guards (#17, #18) —
  several checks could not fail because the list or set they iterated could be
  empty, or pinned Ecto's message text instead of its error metadata. No
  behaviour change; not shipped in the package (`test/` is excluded from the
  Hex `files:` list).

## 0.4.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.4.0 - 2026-08-11

### Changed

- **`phoenix_kit_consent_logs`' future shape now belongs to a module-owned
  migration chain** (#16), `PhoenixKit.Modules.Legal.Migrations`, marker
  `pkl_schema:<N>`. V1 is an **adoption, not a create**: core's V135 baseline
  still creates the table on every install, and V1 re-asserts that exact shape
  idempotently and stamps the marker. Because no shape changes, core's
  `ExpectedSchema` stays accurate — **no core release is required and there is
  no release-ordering hazard**.

  This revisits the same-day 0.3.0/0.3.1 "core owns it" pin deliberately. That
  cleanup killed two drifted in-package DDL copies and stands; this is the
  extraction it made safe, with the drift class solved at the root —
  `up_statements/1` interpolates `ConsentLog.column_widths/0` and there is no
  second copy of those numbers anywhere in the package.

  **`down/1` can never drop the table.** It unstamps the marker and nothing
  else: the rows are a GDPR/CCPA consent audit trail and on most installs the
  table is core-created. Test-pinned — no statement in either direction may
  match `DROP`/`TRUNCATE`/`DELETE`.

  Existing hosts: upgrade, then `mix phoenix_kit.update`; a wrapper migration
  stamps `pkl_schema:1` and nothing else changes. New hosts and hosts without
  Legal: unchanged.

  The V2+ shape-change protocol (core's `@excluded_exact` + manifest
  regeneration, then a core-floor bump here) is in
  `dev_docs/reports/2026-08-10-consent-logs-extraction.md`.

- Carries core's rustler escape hatch (`{:rustler, ">= 0.0.0", optional: true}`)
  so MDEx's NIF builds from source on OTP versions shipping no compatible
  precompiled NIF.

### Added

- The ownership test now cross-checks **every column** against core's manifest
  — names, types, defaults and nullability — not only the varchar widths. A
  width-only comparison passes while a type, a default or a `NOT NULL` drifts,
  which is the same blind spot that produced three disagreeing DDLs in the
  first place.

## 0.3.2 - 2026-08-10

### Fixed

- **The consent policy version never changed, so no visitor was ever re-prompted
  to consent after a policy update.** `list_generated_pages/0` read each page's
  timestamp from `metadata.updated_at`, a key Publishing has never emitted — its
  post map carries the content timestamp at the top level, as
  `content_updated_at`. The field was therefore permanently `nil`, and
  `get_auto_policy_version/0` permanently fell through to the manual
  `legal_policy_version` setting, which the admin UI exposes no input for. The
  version stayed at its `"1.0"` default for the life of the install, which is the
  opposite of what versioning it is for.

- **Column-width checks counted the wrong unit.** Postgres counts `varchar(n)` in
  characters — code points — while `validate_length/3` and `String.length/1`
  count graphemes. The two agree on ASCII and part ways on combining marks and
  ZWJ sequences: 20 graphemes of `"é"` is 40 code points, which passed both the
  changeset added in 0.3.0 and the producer guard added in 0.3.1, then came back
  from Postgres as the raw `Postgrex.Error` varchar overflow those checks exist
  to replace. `ConsentLog.create/1` is public API, so the caller had no way to
  check first. `validate_column_widths/1` now passes `count: :codepoints`, and
  `Legal.update_policy_version/1` counts `String.codepoints/1`.

- **`format_version_date/1` could emit a version wider than the column.** It
  returned an unparseable timestamp string verbatim, and its output becomes
  `consent_version`. An offset-less ISO8601 string with microseconds
  (`"2026-08-10T22:03:27.123456"`) does not parse and is 26 characters — over
  core's `varchar(20)`, which would have rejected every consent write afterwards.
  It now falls back to the width-guarded `get_policy_version/0`, matching the
  catch-all clause.

### Changed

- `ConsentLog.log_consents/2` documents its behaviour inside a caller's
  transaction. Ecto nests without a savepoint, so the rollback on a failed entry
  aborts the caller's transaction too and the function does not return —
  `{:error, errors}` surfaces from the outermost `transaction/1`. Callers that
  need their own work to survive a failed consent write must run it outside their
  transaction.

- `ConsentLog.column_widths/0` states that its numbers are code points, since its
  purpose is to be read by producers and a producer reading the right number in
  the wrong unit is back to the drift the map was introduced to end.

## 0.3.1 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Removed

- **`priv/migrations/add_phoenix_kit_consent_logs.exs`, and the README step that
  told you to run it.** This was a *third* definition of `phoenix_kit_consent_logs`
  (after core's and the coordinator removed in 0.3.0), and the only one that
  could actually break an install:

  - It used `create table`, **not** `create_if_not_exists`. On any host where
    core had already created the table — which is all of them, since core V43 —
    `mix ecto.migrate` failed with `table "phoenix_kit_consent_logs" already
    exists`.
  - Every string column was the Ecto default `varchar(255)`, against core's
    `varchar(64)`/`(30)`/`(20)`/`(45)`/`(64)`, with Ecto-default index names —
    a third naming scheme distinct from core's and the coordinator's.

  `mix phoenix_kit_legal.install` never pointed at this file; it has always
  printed `mix phoenix_kit.update`, which is correct. The README and the install
  task had been contradicting each other. README step 1 now matches the task.

  **If you previously ran this template successfully**, your host predates core
  creating the table and your columns are 255-wide with Ecto-default index names.
  `mix phoenix_kit.doctor` (core 2.0) reports the divergence and
  `mix phoenix_kit.repair` is the supported way to reconcile it. Nothing in this
  package will touch it.

### Added

- **`test/consent_logs_ownership_test.exs`** — fails if a `migration_module/0`, a
  migration coordinator module, or a `priv/` migration template reappears, and
  pins `ConsentLog`'s length validations to core's exact column widths. Each
  regression case was verified by reintroducing the condition and confirming the
  test fails, not merely that it passes.
- A schema-ownership section at the top of `AGENTS.md`, so the next contributor
  sees the constraint before writing a migration.

### Documentation

- `dev_docs/reports/2026-08-10-module-migration-versioning.md` rewritten for
  review by the module's original author: the full evidence chain (commit
  `801e66ca`, V43's original DDL, the `phoenix_kit.update` ordering, core's
  `ExpectedSchema`), all three DDLs side by side, and the finding that PR #8 —
  while correctly fixing the version-tracking protocol — made the coordinator's
  `DROP TABLE ... CASCADE` reachable against a core-owned table for the first
  time.

## 0.3.0 - 2026-08-10

Requires `phoenix_kit ~> 2.0`, unchanged from 0.2.0.

### Removed

- **`migration_module/0` and the standalone consent-logs migration.**
  `phoenix_kit_consent_logs` is a **core** table, not this package's, and this
  package's migration had never run on any host — nor could it.

  Legal began life inside core: the same commit that added "Legal Module Phase 1"
  added core's **V43**, which created the table. When this package was extracted,
  core kept V43, and a *fresh* coordinator was written here from the Ecto schema
  rather than copied from V43 — so the two DDLs drifted. Core's V43 DDL now lives
  in the squashed **V135** baseline, which is unconditional: the table exists on
  every phoenix_kit install, with or without this package.

  It could never run for two independent reasons. Core's chain migrates before
  module migrations in the same task, and both DDLs are
  `CREATE TABLE IF NOT EXISTS` — so by the time this module's `up/1` was reached,
  the table already existed.

  It still mattered, because `down/1` ran
  `DROP TABLE IF EXISTS phoenix_kit_consent_logs CASCADE` against a table core
  owns and that outlives this package. While the version was inferred from table
  existence that rollback looked unreachable; repairing the version marker would
  have armed it. Core 2.0 also added `PhoenixKit.Migrations.ExpectedSchema`,
  which names this table, all 11 columns, 6 indexes and the pkey as core-owned
  and is what `mix phoenix_kit.doctor` / `mix phoenix_kit.repair` verify against
  — so the divergent shape was one core would report as damage.

  **No runtime change:** a migration that never ran cannot stop running. Any
  future change to this table belongs in core's chain.

  Full analysis: `dev_docs/reports/2026-08-10-module-migration-versioning.md`.

### Fixed

- **`ConsentLog` had no length validations, on any field.** Core's columns are
  narrower than the deleted DDL assumed — `session_id` is `varchar(64)` (this
  package assumed 255) and `consent_version` is `varchar(20)` (assumed 50).
  `ConsentLog.create/1` is public API host apps call, so an over-long value came
  back as a raw Postgres varchar-overflow error instead of a changeset error the
  caller could handle. Now validated at core's exact widths: `session_id` 64,
  `consent_type` 30, `consent_version` 20, `ip_address` 45, `user_agent_hash` 64.

## 0.2.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

- `phoenix_kit_publishing` raised to `~> 0.5` in step: its 0.5.0 is the first
  release requiring core 2.0, so the old `~> 0.1` pin could only have resolved a
  publishing that still required core 1.7 — an unsatisfiable set alongside
  `phoenix_kit ~> 2.0`.

### Known issue (resolved in 0.3.0)

- This module's migration coordinator conflicted with core's ownership of
  `phoenix_kit_consent_logs`. Resolved in 0.3.0 — see that entry.

## Unreleased

### Fixed
- **`css_sources/0` no longer emits the same directory twice.** On a normal Hex
  install the callback returned both `:phoenix_kit_legal` and a compile-time
  absolute source root, and the host's generated
  `assets/css/_phoenix_kit_sources.css` came out with two directives pointing at
  one directory:

  ```css
  @source "../../deps/phoenix_kit_legal";
  @source "/www/app/deps/phoenix_kit_legal";
  ```

  The absolute entry was added deliberately in 0.1.9 so `path:` deps resolve, on
  the stated assumption that the pair collapses for Hex installs. It doesn't:
  `Mix.Tasks.Compile.PhoenixKitCssSources` runs `Enum.uniq/1` over the raw
  callback results — an atom and a string, never equal — and formats them into
  path strings only afterwards. No other PhoenixKit module returned an absolute
  root, so Legal was the only duplicated entry.

  Effects were cosmetic in the common case (Tailwind scanned the directory
  twice, and the file is regenerated every compile so it self-corrects per
  machine), but the absolute path is baked in when *this dep* is compiled, which
  made a generated file host-specific: git churn if it is committed, and a
  `@source` that matches nothing if `_build` is carried across a path change,
  such as a multi-stage Docker build that compiles under one prefix and runs
  under another.

  The absolute root is now returned only when it is not already what the
  `:phoenix_kit_legal` entry resolves to. Path deps, umbrellas, and vendored
  checkouts keep the fallback; standard installs get one directive.

- **The comment justifying the old behaviour said the compiler de-duplicated the
  pair via `Enum.uniq/1`.** It reads on the wrong side of the formatting step.
  Replaced with the actual ordering, so the claim is checkable against
  `compile.phoenix_kit_css_sources.ex`.

### Added
- `test/phoenix_kit_legal/css_sources_test.exs` — pins the deps/, path-dep, and
  umbrella layouts, and asserts `css_sources/0` never lists a directory the atom
  entry already covers.

## 0.1.10 (2026-08-03)

### Removed
- **`PhoenixKitWeb.Controllers.ConsentConfigController` — core owns the
  consent-config endpoint now.** ([#12](https://github.com/BeamLabEU/phoenix_kit_legal/pull/12),
  by @mdon; pairs with [phoenix_kit#677](https://github.com/BeamLabEU/phoenix_kit/pull/677))

  `GET /phoenix_kit/api/consent-config` was always routed by core, not by this
  package — core declared the route and picked the controller's module name, and
  this package supplied a module to match it. That only worked while core declared
  the route *conditionally* on this package being loaded: an install without it
  answered `Phoenix.Router.NoRouteError`, because the vendored JS bundle asks for
  the endpoint whether or not Legal is installed.

  Core now declares the route unconditionally and answers it itself, with 204 when
  this package is absent and the usual JSON — delegated to
  `Legal.get_consent_widget_config/0` — when it is present. Nothing here referenced
  the controller, and the endpoint's behaviour with Legal installed is unchanged.

### Changed
- **`{:phoenix_kit, "~> 1.7.189"}` → `{:phoenix_kit, "~> 1.7.227"}`.** This is a
  hard requirement of the removal above, not a routine bump. Core declares the
  consent-config route whenever `PhoenixKit.Modules.Legal` is loaded, and before
  1.7.227 that route points at the controller this package used to define. On an
  older core the route would resolve to a module that exists nowhere and raise
  `UndefinedFunctionError` — a logged 500 on every page load where the widget was
  not server-rendered, which includes authenticated users
  (`legal_hide_for_authenticated` defaults to `true`). Phoenix compiles routes to
  literal tuples, so nothing would have warned at compile time.

  **Upgrading from 0.1.9 or earlier requires `phoenix_kit` 1.7.227+.** The reverse
  order is safe: core 1.7.227 with legal ≤ 0.1.9 simply leaves this package's old
  controller unused, since core's is deliberately named
  `PhoenixKitWeb.Controllers.ConsentConfig` rather than reusing the published name.

### Documentation
- README and AGENTS.md no longer list the deleted controller, and the "API Endpoint"
  section now says who owns the route. Its cache header was documented as "cached
  publicly for 60 seconds" — stale since it became `private, max-age=60`, which is
  deliberate: the payload embeds locale-dependent translations, so it is cacheable
  per user but must never be shared.
- AGENTS.md gains a "Consent Config Endpoint Contract" section recording the
  ownership split and the release-ordering rule, next to the existing
  `reserved_route_prefixes/0` note.

## 0.1.9 (2026-07-25)

### Fixed
- **`publish_page/2` silently did nothing — pages stayed drafts and kept 404ing,
  including via the admin "Publish" button.** ([#11](https://github.com/BeamLabEU/phoenix_kit_legal/issues/11),
  reported by @timujinne)

  It published by calling `Publishing.update_post/4` with
  `%{"status" => "published"}`. Publishing deliberately refuses that write —
  `deferred_publish_status/1` drops a `"published"` value, because the status and
  `active_version_uuid` must be set in one transaction; splitting them let a save
  commit `status=published` while the paired publish rolled back, leaving a post
  that reads published with no active version. `Versions.publish_version/4` is
  that transaction, and `publish_page/2` never called it.

  So the version stayed `draft`, `active_version_uuid` stayed `NULL`, and
  Publishing's public dispatch — which serves only posts with an active version —
  returned 404. `update_post/4` still succeeded, so `publish_page/2` returned
  `{:ok, post}` and the admin flashed "Page published successfully". Nothing
  surfaced the failure.

  `publish_page/2` now calls `publish_version/4` on the post's current version,
  matching how Publishing's own admin publishes (`Web.Listing.apply_status_change/4`).

  **This was the remaining reason `/legal/:slug` 404'd after the 0.1.7 routing
  fix.** The two are independent: 0.1.7 restored the route, and a page still had
  to be genuinely published to be served. Anyone who published via the admin
  button or `publish_page/2` had pages that were never published at all.

### Added
- `publish_page/2` accepts a `:version` option to publish a specific version;
  it defaults to the post's current version.

### Changed
- `publish_page/2` re-reads the post after publishing, so the returned
  `{:ok, post}` carries the post-publish state rather than the pre-publish one.
  The return contract is unchanged.
- The audit trail now records the acting user. `publish_version/4` audits by
  `:actor_uuid` and ignores the `:scope` that `update_post/4` accepts, so the
  scope callers pass is resolved to a user uuid rather than dropped.
- **Admin settings read the correct scope assign.** `Web.Settings` passed
  `scope: socket.assigns[:current_scope]` for all three actions (generate,
  publish, generate all), but PhoenixKit mounts the scope as
  `:phoenix_kit_current_scope` (`PhoenixKitWeb.Users.Auth`), so the value was
  always `nil` and every admin action logged a `nil` actor. Pre-existing, and it
  would have made the audit-trail improvement above a no-op for the admin UI —
  the only place most people publish from. Found in independent review of this
  release.
- Corrected the stale `phoenix_kit ~> 1.7.170` dependency note in
  `PhoenixKitLegal`'s moduledoc; `mix.exs` has required `~> 1.7.189` since 0.1.6.

## 0.1.8 (2026-07-25)

Documentation and packaging follow-up to 0.1.7. No behaviour changes — the
`/legal` routing fix itself shipped in 0.1.7 and is unchanged here.

### Fixed
- **HexDocs "Source" links 404'd on every release.** `docs.source_ref` was
  `"v#{@version}"`, but this repo's tags are bare version numbers (`0.1.7`, not
  `v0.1.7`) as documented in `AGENTS.md` — so every source link pointed at a tag
  that has never existed. Now `@version`.
- ExDoc reference to `c:PhoenixKit.Module.reserved_route_prefixes/0` in the 0.1.6
  entry below was written as a function; it is a `@callback`, which ExDoc resolves
  only via the `c:` prefix. `mix docs` is now warning-free.

### Added
- **Upgrade guide** — new "Upgrading" section in `README.md` and "Upgrade notes"
  under 0.1.7 below: the commands to run, how to verify, the two reasons a page
  can still 404 afterwards (pages left in `draft`, or a leftover `/legal` route
  from the 0.1.6 workaround), and what is deliberately *not* required (no new
  migration, no cache clearing, no config or router changes).

## 0.1.7 (2026-07-25)

### Fixed
- **Public legal pages 404'd on every host app that hadn't hand-written a
  `/legal` LiveView.** 0.1.6 added `reserved_route_prefixes/0` returning
  `["legal"]`, which tells `phoenix_kit_publishing`'s catch-all dispatch to
  leave `/legal` alone so a host-app LiveView can own it. No such LiveView
  ships with this module, none is generated by `mix phoenix_kit_legal.install`,
  and none was documented — so for any host that didn't happen to have one,
  the reservation removed `/legal` and `/legal/:slug` from Publishing's
  dispatch without anything taking over. Pages that had been rendering since
  the module shipped started returning 404, including the links the cookie
  consent widget shows to every visitor.

  The reservation was introduced to fix a real SEO defect — publishing-served
  pages canonicalized to `"/"` because the public controller never assigned
  `:url_path`, and Google dropped them as duplicates. That defect was fixed at
  its source in `phoenix_kit_publishing` 0.2.3 by the `assign_url_path` plug in
  `Web.Controller`, which shipped the same day (PRs #27–#29). With canonical /
  `og:url` / hreflang now correct on publishing-served pages, the reservation
  had no remaining benefit and only the 404 cost.

### Changed
- **Legal no longer implements `reserved_route_prefixes/0`** — it falls back to
  the behaviour's `[]` default. Generated pages are served by Publishing's
  `/:language/:group/*path` dispatch at `/legal` and `/legal/:slug`, with
  language prefixes, translations, and in-place editing handled like any other
  Publishing group. This restores the module's original division of labour:
  Legal generates content, Publishing renders it. No host-app action is
  required — remove any `/legal` route added to work around 0.1.6.
- Documented the public-page contract in `README.md` (new "Public Legal Pages"
  section) and `AGENTS.md`. Its absence is what made the 0.1.6 regression hard
  to diagnose: the only written trace of the routing rule was a source comment
  in `phoenix_kit_publishing`'s `router_dispatch.ex`.

### Upgrade notes

```bash
mix deps.update phoenix_kit_legal phoenix_kit_publishing
mix phoenix_kit.update      # apply any pending schema migrations
# restart the app
```

Requires `phoenix_kit ~> 1.7.189` (both modules), and
`phoenix_kit_publishing ~> 0.4.4` for the matching README documentation. Verify
with `curl -I https://yoursite/legal` — expect `200`, not `404`.

**If it still 404s**, two causes, in order of likelihood:

1. **Pages are still drafts.** Upgrading publishes nothing. Publishing 404s
   unpublished posts for anonymous visitors, so a page generated but never
   published stays invisible. Publish from `/admin/settings/legal`, or check
   `Legal.all_required_pages_published?/0`.
2. **A leftover `/legal` route from the 0.1.6 workaround.** Delete it — Publishing's
   dispatch rewrites the path in the router's `call/2` before route matching, so
   the route is unreachable regardless of its position in `router.ex`.

**Not required:** no new migration (the `phoenix_kit_consent_logs` schema is
unchanged — `mix phoenix_kit.update` is listed only because it's idempotent and
catches pending core migrations), no cache clearing (group-slug resolution is a
live per-request DB lookup and reserved prefixes are recomputed per call), and no
config, settings, or router changes. Run `mix phoenix_kit.assets.rebuild` only if
the consent widget renders unstyled.

## 0.1.6 (2026-07-03)

### Added
- `reserved_route_prefixes/0` (`@impl PhoenixKit.Module`) declares `"legal"` as a
  reserved top-level route prefix, so Publishing's `/:language/:group/*path`
  catch-all dispatch can be told to leave the host app's own `/legal` route alone
  instead of treating the `"legal"` Publishing group Legal creates as one of its
  own groups. Requires `phoenix_kit` ≥ 1.7.170 (adds the callback) and a
  `phoenix_kit_publishing` release that consults
  `PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0` in its dispatcher —
  declaring the prefix here is a no-op until both are in place. (#9)

### Changed
- Bumped `phoenix_kit` dependency floor to `~> 1.7.170` — the version that
  introduces `c:PhoenixKit.Module.reserved_route_prefixes/0`, which this module now
  implements under `@impl`.

## 0.1.5 (2026-05-22)

### Fixed
- `Migrations.ConsentLogs` now implements the versioned-migration protocol PhoenixKit Core v1.7.119 (schema V121) expects — `current_version/0` and `migrated_version_runtime/1` — and `up/1`/`down/1` accept the keyword list Core passes (`prefix:`, `version:`) as well as the legacy map. Previously, on a clean install against the new Core, `mix phoenix_kit.update` silently skipped the Legal migration and `phoenix_kit_consent_logs` was never created (existing installs were unaffected). (#8)

### Changed
- Translated the `ConsentLogs` migration's docstrings and comments to English (no logic or SQL change)

## 0.1.4 (2026-05-09)

### Changed
- All module-owned `gettext` calls now resolve through `PhoenixKit.Modules.Legal.Gettext` instead of the parent app's `PhoenixKitWeb.Gettext` — completes the per-module-i18n migration started in 0.1.3 (`legal.ex`, `web/cookie_consent.ex`, `web/settings.ex`)
- `translate_title/2` resolves page titles against the module's own catalogue under `priv/gettext/`, so generated legal pages get titles in the user's locale even on parent apps that don't translate these strings themselves
- `priv/gettext/default.pot` is now auto-extracted (`mix gettext.extract --merge`) — covers tab labels, page titles, consent-widget UI, and admin flash messages (126 msgids); `__extract_strings__/0` seeds runtime-only strings for the extractor

### Added
- Russian (`ru`) and Estonian (`et`) translations for the entire catalogue: consent-widget banner / modal / category names, page titles, settings labels, flash messages
- `Plural-Forms` header on `priv/gettext/en/LC_MESSAGES/default.po`
- Per-locale tests for the module's own catalogue (`translate/2` smoke tests covering page titles + consent-widget strings) — runnable against any `phoenix_kit` release; tab-label tests remain gated behind `:requires_phoenix_kit_i18n_api` until [BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522) ships

### Notes
- Sidebar tab label still falls back to the raw "Legal" string on `phoenix_kit` ≤ 1.7.105: `Tab.localized_label/1` and the `gettext_backend:` field on `%Tab{}` ship with phoenix_kit#522, which is unmerged. Consent-widget strings and page titles already resolve per-locale on the published `phoenix_kit` because they're rendered live from our own modules.

## 0.1.3 (2026-04-30)

### Added
- `mix phoenix_kit_legal.install` task — auto-patches host app's `endpoint.ex` (Plug.Static), `assets/css/app.css` (Tailwind `@source`), and `assets/js/app.js` (consent IIFE import); idempotent
- `migration_module/0` callback returning `PhoenixKit.Modules.Legal.Migrations.ConsentLogs` — migration runs via `mix phoenix_kit.update`
- i18n: `Legal.get_consent_widget_config/0` returns a `translations` map (banner / modal / categories); JS reads via `t()` / `tc()` helpers with English fallbacks
- Legal page titles translated at generation time via `Gettext.with_locale/3` so per-language Publishing slots receive the title in the right language
- New `phoenix_kit_current_scope` attr on `cookie_consent/1` — component decides server-side whether to render for authenticated users

### Changed
- Server-side auth gate for cookie consent widget: `cookie_consent/1` now returns `~H""` for authenticated users when `hide_for_authenticated?` is true, eliminating the client-side flash and the auth round-trip
- Default for `legal_hide_for_authenticated` flipped from `false` to `true` — existing installs that want the widget visible to authenticated users must set this explicitly in Admin → Legal
- `/api/consent-config` cache header changed from `public, max-age=60` to `private, max-age=60` (translations are locale-dependent)
- Locale prefix dropped from widget links (`/en/legal` → `/legal`) so the parent app's locale plug picks the user's current locale on click
- `css_sources/0` returns `[:phoenix_kit_legal, @source_root]` — absolute source root included for path-dep installs

### Removed
- `should_show`, `is_authenticated`, `hide_for_authenticated` fields from `/api/consent-config` JSON response — auth-gating is now server-side only
- `resetGoogleConsentMode` JS helper — over-broad heuristic, removed

### Fixed
- Banner and modal no longer hidden by Tailwind's `hidden` class `!important`
- Consent widget initializes reliably from `DOMContentLoaded` outside LiveView scope
- Server-rendered consent HTML preserved (no JS re-injection layout flicker)
- HTML escaping (`escapeAttr` / `escapeText`) applied to user-controlled URLs and translation strings in the JS injection path
- Component accepts `cookie_policy_url` / `privacy_policy_url` / `legal_links` again as no-op attrs for backward compatibility with PhoenixKit default layouts

### Internal
- Test infrastructure: `test_helper.exs` starts `PhoenixKit.Cache.Registry` and `:settings` cache for component tests
- Credo `--strict` clean (resolved 5 nested-module references in tests, 1 single-branch `cond`, 1 deeply-nested function)
- Dialyzer clean (`:mix` added to `plt_add_apps`)

### Migration notes
- Recommended (not required): add `phoenix_kit_current_scope={@phoenix_kit_current_scope}` to your `<.cookie_consent ...>` call so the "Hide for authenticated users" admin setting takes effect. Without it the widget renders for everyone.

## 0.1.2 (2026-04-05)

- Fix Legal settings route 404 by adding missing `live_view` field to settings tab definition
- Add `version/0` callback to display actual package version on modules page
- Add `elixirc_options: [ignore_module_conflict: true]` for umbrella compatibility
- Update dependencies to latest versions

## 0.1.1 (2026-04-02)

- Migrate select elements to daisyUI 5 label wrapper pattern
- Remove deprecated `select-bordered` class for daisyUI 5 compatibility
- Add `live_view` to settings tab for auto route discovery
- Add `css_sources/0` callback
- Fix legal page generation for existing/trashed posts

## 0.1.0 (2026-03-27)

- Initial extraction from PhoenixKit core
- Legal page generation (Privacy Policy, Cookie Policy, Terms of Service, etc.)
- Cookie consent widget with Google Consent Mode v2
- GDPR, CCPA, LGPD, PIPEDA compliance frameworks
- Consent logging schema
