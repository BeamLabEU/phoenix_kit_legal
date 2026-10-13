# PR #25 second review

Repo: `BeamLabEU/phoenix_kit_legal`

Reviewed: PR squash `5e143f8`, dependency update `3577edf`, Claude's fixes `b232107`

Reviewer: Codex

Date: 2026-10-13

Verdict: **Approve after the fixes below.** Claude's two fixes are sound, but
the browser flow and origin check had additional defects worth fixing before release.

## Scope

Rechecked the consent endpoint, cookie reader and writer, audit producer,
declaration gathering, settings changes, templates, component and browser script.
Cross-checked the installed core's API pipeline, session/auth access, rate limiter,
widget layout, configuration controller and older bundled consent manager.
No migration, version bump or publication is part of this review.

Claude's fresh hidden-list/fingerprint reads prevent the reported cache race.
The settings event also checks listed keys before hiding them. Those changes
and Claude's review document are preserved.

## Findings fixed

### BUG - HIGH — The origin check discarded the scheme

`own_authorities/2` accepted the Origin's scheme when interpreting the Host
header, and `site_url_authority/0` discarded the configured URL's scheme.
For example, `site_url: https://shop.example:8443` accepted an Origin of
`http://shop.example:8443`. The scheme makes those different origins even
though their cookie host and port match. A cross-origin form can send a
consent map without requiring a JSON/CORS preflight.
With a bare Host header, the same mistake also manufactured the Origin's
default port, allowing an HTTP origin on port 80 to match an HTTPS request
on port 443. The expanded tests cover bare headers as well as explicit ports.

Fixed by checking the request scheme, using `x-forwarded-proto` for TLS
proxies, and retaining `site_url`'s scheme. Host-header port handling remains
independent of the application's listening port. Tests cover both writes,
direct requests, forwarded requests, explicit equal ports with different
schemes, configured URLs, and the existing host/port matrix. Proxy setups
must forward the outside protocol or configure the outside `site_url`.

### BUG - HIGH — In-flight browser requests could reverse a later choice

A reconciliation GET captured the old local decision. If the visitor withdrew
while it was pending, a response reporting no server decision caused that GET
to POST the captured grants again. A delayed GET from a pending revocation
could similarly DELETE a subsequent choice. Independently, rapid POSTs/DELETEs
ran concurrently, allowing their cookie responses to arrive in reverse order.

Fixed with a local decision revision, guards before applying delayed reads or
queueing synchronization, and a per-tab write queue. Superseded responses do
not trigger reloads or clear a newer pending revocation. A failed write releases
the queue so the next decision can still be delivered. Tests exercise delayed
responses, rapid choices, queued failure, and revocation followed by a choice.
The queue orders one tab's requests; it is not a distributed ordering protocol
for independent tabs or applications on another origin.

### BUG - HIGH — Withdrawal left active consumers on the old grants

`revokeConsent()` cleared storage and memory without applying a refusal.
Google Consent Mode and listeners for `phx:consent-updated` therefore stayed
granted when reloads were disabled. A storage exception also prevented DELETE
from being sent. Other tabs applied refusals but ignored the configured reload,
leaving already-running scripts active on those pages.

Fixed by immediately applying denial, isolating storage failure from server
withdrawal, and honoring withdrawal reloads in other tabs. Verified both with
reloads disabled and with a real second-tab reload in Chromium.

### BUG - MEDIUM — Clock skew could discard an undelivered refusal

Claude recorded this as a nitpick. A failed refusal report on a device whose
clock is behind the server could be replaced with the server's old grants.
That reverses an explicit choice, so it is worth fixing.

New decisions now carry a local `pending` flag inside the existing consent
storage value. The flag survives a failed report, gives an undelivered local
choice precedence over server timestamps, and is removed when a POST or GET
confirms the same choice. No new storage key or server payload is introduced.
Tests also ensure a genuinely newer server choice can still be adopted and
successful synchronization remains capped when cookies are refused.

### BUG - MEDIUM — Expired grants survived a LiveView hook remount

Restoring an expired decision deleted storage but left the singleton manager's
old `consent` in memory. `hasConsent()` and previously updated consumers could
therefore remain granted even while the new banner asked again.

Restoration now clears old in-memory choices and applies denial when no live
stored decision remains. A delayed reconciliation also checks that its captured
decision is still current. A regression test reproduces the remount and expiry.

### BUG - MEDIUM — Failed module discovery could produce an empty policy

`fetch_declared/2` discovered enabled modules before starting its bounded task,
through a helper that rescued discovery failures to `[]`. An exit while
checking a module's enabled state became successful empty policy data; a hanging
enabled-state check was outside the timeout altogether.

Discovery now runs inside the task's protected, bounded body and returns an
error to policy generation. Tests exercise discovery exit, discovery timeout,
and refusal to store a generated fingerprint after failure. The tolerant
unlocalized banner discovery remains available for rendering.

### BUG - MEDIUM — Hot-path readers did not fully honor their total-function contract

`objected?/1` raised on non-request input, and `read/1` could raise on malformed
connection fields. This contradicted the documented contract for callers in
other modules. Added a header guard and fallback for GPC, and fail-closed
rescue/exit handling for cookie reading and decoding. Tests cover non-requests,
malformed headers/cookie fields, and `status/2` using those requests.

### IMPROVEMENT - MEDIUM — Hook remounts stacked global listeners

Each mount installed another storage listener and Escape listener. The former
now performs consent changes and reloads, making duplicate callbacks more
than cosmetic. Global listeners are installed once for the singleton manager;
they read the current config and DOM after each remount. Regression test added.

## Remaining improvements

- Core's layout still discards `config.purposes` and the component gathers it
  again. Pass `purposes={config.purposes}` in core. Avoid a new cache here merely
  to compensate for that caller; locale and module/settings invalidation would
  expand this release's scope.
- The policy fingerprint remains global across languages, as Claude noted.
  Per-language generation/publication tracking needs a separate settings and UI
  change. The existing indicator describes the last generation, not proof that
  every published translation is current.
- Unchanged confirmations still retain the original server timestamp and cookie
  expiry. This preserves deduplication and avoids silently extending consent
  during routine synchronization, but a manual repeat can leave browser and
  cookie lifetimes different until the next reconciliation. Refreshing explicit
  confirmations independently of sync merits a separate, documented contract.

## Validation

- Baseline: 340 Elixir tests, zero failures, integration included.
- Final: `PGHOST=postgres-test mix test`: 345 tests, zero failures. The database
  was the existing dedicated `phoenix_kit_legal_test` fixture.
- `node --test test/javascript/consent_test.cjs`: 13 behavior tests passed.
  Six of the first seven tests failed against the previous script; the expiry
  test separately reproduced the old in-memory grant before its fix.
- `test/javascript/consent_browser_test.cjs`: Chromium passed using the actual
  installed core bundle on an HTTP host fixture without a consent component:
  takeover/injection, modal purposes, Escape, denial in both tabs, DELETE/cookie
  removal, rapid-choice ordering, and configured cross-tab reload.
  The browser endpoint is a fixture, not an actual Phoenix application; cookie
  signatures and real audit writes are covered by the Elixir integration suite.
- `mix precommit`: passed, including compile with warnings as errors, formatting,
  strict Credo, Dialyzer, unused-lock check and Hex audit. Hex emitted an expired
  authentication-session warning while continuing its public audit successfully;
  check publishing authentication before the release.

Review/fixes are local. Version stays `0.5.1`; no CHANGELOG release entry,
push, Hex publish, tag or GitHub release was performed.
