# PR #12 Review — Remove the consent-config controller, which core now owns

**Repo:** `BeamLabEU/phoenix_kit_legal`
**Branch:** `mdon:main` → `BeamLabEU:main` (merged as `65d33fa`, commit `a061947`)
**Author:** Max Don
**Reviewer:** Claude Opus 5
**Date:** 2026-08-03
**Related:** `BeamLabEU/phoenix_kit#677` (moves the endpoint into core — merged
2026-08-03, released as `phoenix_kit` **1.7.227** the same day),
[#11](https://github.com/BeamLabEU/phoenix_kit_legal/issues/11) (checked separately,
see the appendix)
**Verdict:** **APPROVE, RELEASE GATED ON A DEPENDENCY FLOOR.** The deletion is right
and the reasoning behind it is right. At review time its precondition was not met —
no *released* `phoenix_kit` carried the replacement, so publishing would have turned
a 404 into a 500 on every page load. Core 1.7.227 closed that window mid-review; the
fix is `{:phoenix_kit, "~> 1.7.227"}`, shipped in 0.1.10 alongside the deletion.

---

## The change

One file deleted, 35 lines, no code references anywhere in the package:
`lib/phoenix_kit_legal/web/consent_config_controller.ex`, which defined
`PhoenixKitWeb.Controllers.ConsentConfigController`.

The premise is correct and worth restating, because it is the part that must survive:
the route `GET /api/consent-config` is declared by **core**, in
`PhoenixKitWeb.Integration`, pointing at a controller whose module name core chooses.
Only one package can own that name. Two definitions in two apps means whichever
`.beam` the code server finds first wins, silently. Core is the right owner, and
`phoenix_kit` 1.7.227 has it: `lib/phoenix_kit_web/controllers/consent_config.ex`,
answering 204 when Legal is absent and delegating to
`Legal.get_consent_widget_config/0` when it is present.

Worth noting what core did *not* do, since it changes this package's risk: the
released module is `PhoenixKitWeb.Controllers.ConsentConfig`, **not**
`…ConsentConfigController`. Core declined to reuse the name this package published,
on the reasoning that moving a responsibility does not un-publish the versions that
still ship it — a host resolving new core against legal ≤ 0.1.9 would have had that
module in two applications with code-path order picking the winner. The rename makes
the pair safe in both upgrade orders. It also means the collision this PR set out to
avoid was already defused from core's side; the deletion remains correct (the old
module is now dead code referenced by nothing), but the *urgent* half of its
rationale is gone, which is precisely why the release could afford to wait for the
floor.

Nothing in this repo referenced the controller — verified by grep across `lib`,
`test`, and `priv`. The deletion is clean.

---

## Findings

### BUG - CRITICAL — Deleted against an unreleased core: 500 on every page load

**Status:** fixed by the `~> 1.7.227` floor below. At review time no released core
carried the replacement; core 1.7.227 shipped during the review and closed the window.

The PR body states core "now declares `GET /api/consent-config` unconditionally".
That is true of core's `main` branch and false of every **released** `phoenix_kit`.
Verified against the actually-vendored dependency rather than the PR's claim:

- Latest on Hex is `phoenix_kit` **1.7.226** (released 2026-08-01). Core main's
  `@version` is still `1.7.226` — phoenix_kit#677 merged 2026-08-03 and has not been
  cut into a release.
- `deps/phoenix_kit` (1.7.226) contains **no** definition of
  `PhoenixKitWeb.Controllers.ConsentConfigController` anywhere. The only mentions are
  the route and a `@compile {:no_warn_undefined, ...}` entry in `integration.ex:11`.
- In 1.7.226 the route is still **conditional**, and the condition is the thing that
  makes this dangerous (`integration.ex:270`):

  ```elixir
  if Code.ensure_loaded?(PhoenixKit.Modules.Legal) do
    get "/api/consent-config", Controllers.ConsentConfigController, :config
  end
  ```

Installing this package is exactly what makes `PhoenixKit.Modules.Legal` loadable. So
on any host running current-release core plus this branch: the route **is** declared,
and the module it dispatches to **does not exist**.

Failure path, end to end:

1. Nothing catches it at compile time. Phoenix compiles routes to literal
   `{plug, opts}` tuples, not remote calls, so the missing module produces no
   undefined-module warning. The host app builds clean.
2. At runtime the dispatch resolves the controller and raises
   `UndefinedFunctionError` — module not available → **500**, logged with a stacktrace.
3. Core's bundled `phoenix_kit.js` requests the endpoint on `DOMContentLoaded`
   whenever `#pk-consent-root` is not already in the DOM
   (`priv/static/assets/phoenix_kit.js:1350-1356`) — i.e. whenever the widget is
   disabled, hidden for an authenticated user (`legal_hide_for_authenticated`
   defaults to `true`), or the page does not render the widget at all. Core's own
   controller moduledoc describes the pre-fix behaviour as "a logged exception on
   every single page load".
4. The JS swallows it (`.catch` → `log`), so nothing is visible in the UI. The host
   just accumulates 500s in its logs, and the manual
   `window.PhoenixKitConsent.init()` entry point — documented in this repo's README
   as public API — stops working.

The change set out to stop core raising `NoRouteError` on installs *without* this
package. Shipped in this order it produces a strictly worse fault on installs *with*
it: a 404 becomes a 500, and it lands on every host that has the package rather than
every host that lacks it.

Nothing broken has reached users. `mix.exs` is at 0.1.9, which is what is on Hex, and
0.1.9 still contains the controller. The defect exists only on `main`, and only
becomes real at `mix hex.publish`.

**Why the fix is a floor and not a restored file.** Restoring the controller would
have put this package back in the business of owning a name core now routes around,
for a window that closed with core's next release. Conditionally defining the module
(`unless Code.ensure_loaded?(...)`) makes module identity depend on dep-compile order
and stale build artifacts. The correct fix is ordering plus a floor: core first, then
`{:phoenix_kit, "~> 1.7.227"}` here, which is what shipped.

Note that the floor does the work in both directions. Core's rename means legal
≤ 0.1.9 is safe against new core on its own; what is *not* safe on its own is legal
≥ 0.1.10 against old core, and that is exactly the direction a version floor can
constrain.

### BUG - HIGH — `:phoenix_kit` floor still admits cores without the controller

**Status:** fixed. `mix.exs` now floors `{:phoenix_kit, "~> 1.7.227"}`.

`mix.exs:63` still reads `{:phoenix_kit, "~> 1.7.189"}`. Even once core ships the
controller, that constraint resolves happily to 1.7.189–1.7.226, none of which have
it. A host on a pinned older core would hit the CRITICAL failure above with no
warning from the resolver.

Deleting a module that another package now owns converts that package's version into
a hard requirement. Left unraised, this is a latent version of the CRITICAL bug that
survives core's release indefinitely — core shipping the replacement does not help a
host whose resolver picked 1.7.226. Raised in the same release that ships the
deletion, with the reasoning inline in `mix.exs` so it is not "tidied" back down.

### BUG - MEDIUM — Documentation still ships the deleted controller

**Status:** fixed in this pass.

PR #12 touched no docs, leaving four references to a file that no longer exists:

- `README.md:338` — architecture tree listing `consent_config_controller.ex`. Removed.
- `README.md:391` — the "API Endpoint" section, which presented the endpoint as this
  package's own. Rewritten to state that core owns the route and the controller
  (naming core's actual module, `…Controllers.ConsentConfig`), that Legal supplies
  only the payload via `get_consent_widget_config/0`, and that core's version is
  therefore a hard requirement. While there: the cache header was
  documented as "Cached publicly for 60 seconds", stale since 0.1.x changed it to
  `private, max-age=60` (see `CHANGELOG.md:191` — translations are locale-dependent,
  so a shared cache would serve one locale's strings to another's reader).
- `AGENTS.md:41` — key-modules list. Removed.
- `AGENTS.md:142` — file-layout tree. Removed.

Also added an AGENTS.md contract section, "Consent Config Endpoint Contract",
alongside the existing `reserved_route_prefixes/0` note. It records who owns the
endpoint, that the module must not be redefined here, and the release-ordering rule —
so the next agent to look at this does not "restore the missing controller" and
recreate the collision, or re-delete it against the wrong core.

### NITPICK — `dev_docs/superpowers/specs/` references are stale, deliberately left

`2026-04-19-server-side-consent-auth-gate.md` still describes the controller as
living here. It is a dated design spec, not current documentation; rewriting history
in a spec is worse than leaving it. Noted, not changed.

---

## Action taken

Core released 1.7.227 on 2026-08-03, which unblocked the sequence. Shipped as
**0.1.10**:

1. `{:phoenix_kit, "~> 1.7.189"}` → `{:phoenix_kit, "~> 1.7.227"}`, with the
   reasoning inline so a future cleanup does not lower it.
2. CHANGELOG entry under 0.1.10 covering the removal, the floor, and the fact that
   cores before 1.7.227 are no longer supported.
3. README and AGENTS.md corrected to core's real module name and the concrete floor.
4. `mix precommit` clean, then publish.

For the record, since the ordering rule outlives this PR: releasing this package
before core was the one sequence that breaks hosts. Core first breaks nothing —
its controller answers 204 when Legal is absent, and its rename means legal 0.1.9's
own controller is simply orphaned rather than contested.

---

## Appendix — Issue #11 (`publish_page/2` silent no-op)

Checked as asked; **no action needed, already fixed and released.**

`publish_page/2` (`legal.ex:852`) published by calling `update_post/4` with
`%{"status" => "published"}`, which `phoenix_kit_publishing` deliberately drops
(`deferred_publish_status/1`) because status and `active_version_uuid` must be set in
one transaction. So the post stayed a draft, `active_version_uuid` stayed `NULL`,
`/legal/:slug` kept 404ing — and `{:ok, post}` came back anyway, so the admin's
Publish button flashed success and changed nothing.

Fixed in `3927e30`, which routes through `Versions.publish_version/4` (the atomic
transaction), preserves the `{:ok, post}` contract by re-reading the post, resolves
the scope to an `:actor_uuid` for the audit trail, and adds a `:version` opt.
Follow-up `13ff785` fixed a related pre-existing defect found in review: `Web.Settings`
read `socket.assigns[:current_scope]`, but PhoenixKit mounts the scope as
`:phoenix_kit_current_scope`, so every admin action had been logging a nil actor.

Both shipped in **0.1.9**, which is live on Hex. The reporter has been asked to
confirm and close. The one open caveat is unchanged and belongs on the record: this
package's suite is DB-free, so no test exercises the fixed path end to end — the
verification that exists is @timujinne's manual confirmation that
`publish_version/4` restores 200s.
