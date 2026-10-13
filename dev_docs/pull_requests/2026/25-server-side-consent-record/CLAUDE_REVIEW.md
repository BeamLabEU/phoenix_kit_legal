# PR #25 Review — Add a server-side record of consent and the list of what the site collects

**Repo:** `BeamLabEU/phoenix_kit_legal`
**Commit:** `5e143f8` (squash-merged to `main`)
**Author:** Max Don
**Reviewer:** Claude Sonnet 5.5
**Date:** 2026-10-13
**Verdict:** **APPROVE with two small post-merge fixes.** No correctness or
security defect found in the consent endpoint, the cookie, or the banner's
server reconciliation. One stale-cache race and one unvalidated client key are
fixed below; four limitations are recorded and deliberately left.

---

## Overview

Before this PR a visitor's decision lived only in `localStorage` and nothing
wrote to `phoenix_kit_consent_logs`. The PR adds:

- `GET/POST/DELETE {prefix}/api/consent` (`Legal.Routes` →
  `Web.ConsentController`), piped through `:phoenix_kit_api`, plus a signed
  `pk_consent` cookie (`Legal.Consent`) that other modules read without a
  query.
- A rewritten banner script that reports each decision, reconciles with the
  server once per session, retries a failed revocation, and retires the older
  copy bundled in core's `phoenix_kit.js`.
- `Legal.DataCollection`: modules export `data_collection/0` (found by name);
  the preferences dialog, the settings page and the generated Cookie Policy
  read the same list.
- Settings for the record, an `opts` thread through every settings writer so
  core's settings history names the admin, and Gettext for all of it.

Verified by reading the producing code rather than the PR text:

- `RateLimiter.Backend.hit/3` (Hammer 7, `use Hammer, backend: :ets`) and
  `IpAddress.network/1` exist in core 2.62.2; the controller's feature-detection
  of `network/1` is correct and its `rescue`/`catch :exit` makes an unstarted
  limiter fail open, as the comment says.
- Core's `AssetsController`, `ConsentConfig` and `LayoutWrapper` call the
  Legal API exactly as `AGENTS.md` describes; `ConsentConfig` returns
  `get_consent_widget_config/0` verbatim, so `consent_endpoint`, `cookie_days`
  and `purposes` reach the injected-widget path with no core change.
- The `js_sources/0` entry matches `normalize_entry/1` in core's
  `:phoenix_kit_js_sources` compiler (`app`, `file`, `global`).
- `update_boolean_setting_with_module/4` is `update_setting_with_module/4` with
  `"true"`/`"false"`, so `Consent.update_settings/2` writing booleans through
  the string writer stores the identical row.
- The same-origin check: `Origin: null` and an unparsable `Origin` fall to
  `Sec-Fetch-Site`; `same-site` (a sibling subdomain, which shares the cookie)
  is refused; the port is compared; the plug order puts the same-site check
  before the rate limit, so cross-site noise cannot spend a visitor's bucket.
- `Consent.decode/2` cannot raise on any cookie value: `MessageVerifier.verify`
  returns `:error`, `Jason.decode` is matched, and `from_payload/1` has a
  catch-all.
- Russian has three plural forms for `%{count} day(s)`; no `#, fuzzy` entry is
  left in any catalogue.

Baseline before my changes: `mix test` 317 tests, 0 failures (integration
excluded); with the fixture database created, 340 including mine, 0 failures.

## Findings

### BUG - MEDIUM — The settings page could report the policy as outdated from stale cache reads (fixed)

`PhoenixKit.Cache.invalidate/2` is a `GenServer.cast`, so the settings cache
trails a write. The PR knew this for the hidden list and fixed
`assign_collection/2` to read it fresh and hand it back. But the same function
then called `DataCollection.policy_outdated?/0`, which re-reads **both** inputs
through the cache:

- the hidden list, via `listed/1` → `hidden_keys/0`; and
- the stored fingerprint, via `Settings.get_setting_cached/2`.

After ticking an entry off, or after generating the Cookie Policy (which
rewrites the fingerprint), the "This list has changed since the Cookie Policy
was generated" alert could be computed from the state before the write — the
exact symptom the PR's last commit fixed for the warnings, one call further
down. The window is small (a task is spawned in between) but not zero, and the
alert is the only thing telling an operator the published policy is stale.

**Fix:** `policy_outdated?/1` takes `:hidden`, `:fresh` and `:modules`;
`listed/2` takes `:hidden`; `Legal.fresh_setting/2` reads a string setting from
the setting itself (beside the existing `fresh_json_setting/2`).
`assign_collection/2` passes `hidden: hidden, fresh: true`. The no-argument
forms are unchanged. Tests: the argument wins over a stale cached list; `fresh:`
wins over a stale cached fingerprint; `listed/2`.

### IMPROVEMENT - MEDIUM — `toggle_collection` stored any key the client sent (fixed)

`handle_event("toggle_collection", %{"key" => key}, …)` appended whatever the
event carried to `legal_hidden_collection`. Only an admin with the `legal`
permission can send it, but the list is persisted, is read on every page that
renders the banner, and nothing would ever remove a junk key (the settings page
shows only declared entries). **Fix:** hiding requires
the key to be one of the entries on the page; un-hiding stays unconditional,
so a key hidden for a module since disabled can still be cleared. Test added.

### IMPROVEMENT - MEDIUM — Every page render gathers all declarations twice (not fixed)

Core's `LayoutWrapper` calls `Legal.get_consent_widget_config/0`, which now
includes `purposes` (`consent_purposes/0` → `DataCollection.by_category/0` →
`ModuleRegistry.enabled_modules/0` and every module's `data_collection/0`),
passes only the fixed attributes to `cookie_consent/1`, and the component —
getting no `purposes` — calls `Legal.consent_purposes/0` again. That is two
sweeps over the registry per public page view, in the request path, on every
host with the widget on.

Not fixed because the duplicate is created by the call shape in core
(`layout_wrapper.ex`, which discards `config.purposes`), and a cache here would
have to key on the locale, because the titles are translated. The right fix is
for core to pass `purposes={config.purposes}`; the component already accepts it.
Until then the cost is bounded by `enabled?/0` reads that hit the settings
cache. Worth a core issue.

### NITPICK — The Cookie Policy fingerprint is recorded per generation, not per language

`remember_collection/2` stores one fingerprint whichever language was just
generated. Regenerating `cookie-policy` in German clears the "outdated" alert
while the English and French posts are still the old text. `policy_outdated?/0`
cannot tell, by design (one key, one language). Acceptable for a hint; the
alert text could say "in every language" if operators trip on it.

### NITPICK — An unchanged decision does not extend the cookie

`Consent.record/3` returns the existing cookie untouched for an equal decision,
while the banner re-stamps `localStorage` on every click. A visitor who
re-confirms the same choices on day 170 keeps a local decision valid for 180
more days and a server cookie that expires on day 180. It repairs itself — the
next session's reconciliation finds no server decision and re-sends it as
`source: "sync"` — but the audit row then dates the consent from the sync, not
from the click. Left as is: refreshing would add a `Set-Cookie` to every
repeated report, and the re-confirmation is not a new decision for the log.

### NITPICK — Clock skew can make the banner adopt an older server decision

`reconcileWithServer` compares `server.decided_at` (server clock) with the
local timestamp (client clock) when the choices differ. A client clock far
behind the server's can make a stale server decision win over a newer local
one whose report failed. Only reachable with a failed report **and** a skewed
clock; the visitor can decide again. Noted, not worth a protocol change.

### NITPICK — Hook remounts re-add document listeners

`CookieConsentHook.destroyed` clears `initialized`, so each remount runs
`setupCrossTabSync()` and the Escape handler again and the listeners stack.
Pre-existing, but the `storage` handler now dispatches `phx:consent-updated`
once per stacked listener. Same behaviour on the old script; not introduced here.

## Considered and found sound

- **Trust boundary of `x-forwarded-host`.** Accepted as an own-name source; a
  cross-site page cannot set it from a browser, and a non-browser client has no
  visitor cookie to abuse.
- **Fail-open rate limiter.** Documented, and the right default for a consent
  endpoint (refusing to record a refusal is worse).
- **`persistent_term` for refused origins.** Capped at 50 writes per node, host
  length bounded; no unbounded growth from attacker-chosen `Origin`.
- **`describe_failure/1`.** Walks the `{:error, [{:error, changeset}]}` shape
  `ConsentLog.log_consents/2` actually rolls back with and prints field names
  and messages only.
- **Escaping.** Banner text goes through `escapeText`/`escapeAttr`; declared text
  in the policy goes through `markdown_text/1`.
- **Mount queries on the settings page.** `assign_collection/1` and
  `assign_consent_record/1` read in `mount/3`, against the usual LiveView rule,
  but the page already did (`diagnose_legal_pages/0`, framework and company
  reads) and it is an admin page; left consistent with the file.

## Validation

`mix test`: 340 tests, 0 failures, integration included against a freshly
created `phoenix_kit_legal_test`. `mix precommit`: passed (compile
`--warnings-as-errors`, format, `credo --strict`, dialyzer, deps and Hex audit).
Not released: no version bump, CHANGELOG entry, push or publish, as requested.
