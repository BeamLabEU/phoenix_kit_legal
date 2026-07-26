# `publish_page/2` silently no-op'd — pages stayed drafts and 404'd

**Date:** 2026-07-25
**Repo:** `BeamLabEU/phoenix_kit_legal` (fix, 0.1.8 → 0.1.9)
**Issue:** [#11](https://github.com/BeamLabEU/phoenix_kit_legal/issues/11) — reported by @timujinne (Tymofii Shapovalov)
**Reported against:** `phoenix_kit` 1.7.211, `phoenix_kit_legal` 0.1.8, `phoenix_kit_publishing` 0.4.4
**Status:** fixed on `main`, **approved for release** as 0.1.9 (independent recheck signed off 2026-07-26) — still needs tag / GitHub release / Hex
**Related:** [2026-07-25-legal-public-pages-404.md](2026-07-25-legal-public-pages-404.md) (the 0.1.7 routing fix this completes)

---

## Summary

`PhoenixKit.Modules.Legal.publish_page/2` returned `{:ok, post}` without
publishing anything. The post's version stayed `draft`, `active_version_uuid`
stayed `NULL`, and `/legal/:slug` kept returning 404 — because Publishing's
public dispatch serves only posts that have an active version.

The admin **Publish** button in Admin → Legal calls the same function, so it
flashed "Page published successfully" and changed nothing. Nothing anywhere
surfaced the failure.

This was the remaining reason legal pages 404'd after the 0.1.7 routing fix.
The two defects are independent and stacked: 0.1.7 restored the *route*, and a
page still had to be genuinely *published* to be served.

## Root cause

`publish_page/2` published by setting a status field:

```elixir
publishing_module().update_post(
  @legal_blog_slug,
  post,
  %{"status" => "published"},
  scope: scope
)
```

`phoenix_kit_publishing` deliberately refuses that write. From
`lib/phoenix_kit_publishing/posts.ex:1336`:

```elixir
# Drop a "published" status so it is never written outside publish_version/4's
# atomic transaction (see update_version_defaults/4). draft/archived/nil pass
# through unchanged.
defp deferred_publish_status("published"), do: nil
defp deferred_publish_status(status), do: status
```

And the rationale, `posts.ex:1306-1311`:

> `"published"` is NEVER written here — it is set atomically with
> `active_version_uuid` by `Versions.publish_version/4`. Writing it here (a
> separate transaction) let a save commit `status=published` while the paired
> publish rolled back (e.g. empty primary title), leaving a post that reads
> "published" with no active version — admin shows published, public 404s (M4).

So the status was dropped, `update_post/4` still succeeded, and `publish_page/2`
returned its `{:ok, post}` — a success value for an operation that did nothing.

There is an irony worth recording: Publishing added that guard specifically to
prevent "admin shows published, public 404s". Legal called it in precisely the
way the guard neutralizes, and produced that exact symptom by another route.

## The fix

`publish_page/2` now resolves the post and calls `publish_version/4`, matching
how Publishing's own admin publishes (`Web.Listing.apply_status_change/4:954`):

```elixir
version = Keyword.get(opts, :version) || post[:version] || 1

case publishing_module().publish_version(@legal_blog_slug, post.uuid, version,
       actor_uuid: actor_uuid(scope)
     ) do
  :ok -> publishing_module().read_post(@legal_blog_slug, page_slug)
  {:error, reason} -> {:error, reason}
end
```

Four decisions a reviewer should check:

1. **Version resolution.** `post[:version]` is the version `read_post/2`
   resolved, confirmed present in `DBStorage.Mapper.to_post_map/6:71`. This
   matches `listing.ex:954`'s `post[:version] || 1`. A `:version` opt allows an
   explicit choice. *Reviewer: is "current version" right for a regenerated page,
   or should it be max(available_versions)?*
2. **Return contract preserved.** `publish_version/4` returns `:ok | {:error, _}`,
   but `publish_page/2` is specced `{:ok, map()} | {:error, term()}` and
   `Web.Settings.handle_event("publish_page", …)` matches `{:ok, _post}`.
   Returning bare `:ok` would have raised `CaseClauseError` in the admin. The fix
   re-reads the post instead, keeping the contract and giving callers
   post-publish state.
3. **Audit actor.** `publish_version/4` reads `:actor_uuid`
   (`ActivityLog.actor_uuid/1:76`) and does **not** understand the `:scope` that
   `update_post/4` accepts. Passing `scope:` straight through would have silently
   dropped the actor from the audit trail, so a private `actor_uuid/1` resolves
   `scope.user.uuid`.
4. **`@compile {:no_warn_undefined, …}`** gained
   `{PhoenixKit.Modules.Publishing, :publish_version, 4}`. Without it the new
   call warns, and `precommit` runs `--warnings-as-errors`.

## Verification

- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, format check, `credo --strict`, dialyzer) — exit 0
- `mix test` — 38 tests, 0 failures
- Every claim in the issue independently confirmed against source before fixing:
  `legal.ex` call site, publishing's drop guard and its rationale comment,
  `publish_version/4`'s signature and facade delegation
  (`publishing.ex:159`), and the `read_post` map's `:uuid` / `:version` keys

**Not verified: the fix has not been run against a database.** The reporter
verified the *workaround* (`Versions.publish_version/4` directly) restores 200s
on both `/legal` and `/legal/:slug`, which confirms the approach. The fix as
written compiles and passes the gate, but no test exercises it.

## Known gap — no regression test

This module's suite is DB-free (`test_helper.exs` starts no repo), and
`publish_page/2` requires Publishing plus a live database. A test that would
actually have caught this — assert the version's status and `active_version_uuid`
after publishing — cannot run here.

A source-level guard (asserting `publish_page/2` doesn't route through
`update_post/4`) would be brittle and would not catch the class of bug. Recording
the gap rather than adding a test that provides false assurance.

*Reviewer: is there an integration-test harness in a sibling module worth
borrowing? `phoenix_kit_publishing` has DB-backed tests behind an
`:integration` tag.*

## Review requests

Points where a second opinion is most valuable:

- **Version choice** — `post[:version]` vs. the max available version, for a page
  regenerated several times.
- **Partial-failure behaviour** — if `publish_version/4` succeeds but the
  re-read fails, the caller sees `{:error, _}` for a publish that *did* happen.
  Is that the right trade, or should it return `{:ok, post}` with the stale map?
- **Blast radius — swept, clean.** The only other `"status"` writes in
  `legal.ex` are `"draft"` (lines 1305, 1314), which
  `deferred_publish_status/1` passes through unchanged. `publish_page/2` was the
  sole instance. Worth a second pair of eyes on whether the sweep was broad
  enough (it covered `legal.ex` only).
- **Whether 0.1.9 should also carry** the stale `phoenix_kit ~> 1.7.170` pin in
  `lib/phoenix_kit_legal.ex:17` (mix.exs requires `~> 1.7.189`).

---

## Independent recheck (Grok, 2026-07-26)

### Sign-off

**Yes — I agree with what Claude did.** Diagnosis, root-cause path, and the
chosen fix are all correct. No code changes requested from this review.

| Item | Decision |
|------|----------|
| Root cause (`deferred_publish_status` silent drop) | **Agree** |
| Fix via `publish_version/4` | **Agree** — matches Publishing admin |
| Re-read after `:ok` (preserve `{:ok, post}`) | **Agree** |
| `actor_uuid/1` mapping from scope | **Agree** (see pre-existing settings assign nits below) |
| Version default `post[:version] \|\| 1` | **Agree** — keep as written |
| Partial-failure: re-read error after successful publish | **Agree** — keep `{:error, _}` |
| No DB regression test in this package | **Agree** — gap recorded is the right call |
| Ship as **0.1.9** | **Approved** |

**Status after this recheck:** code on `main` (`3927e30`) is ready for tag /
GitHub release / Hex. Remaining work is packaging, not further code changes for
#11.

One related pre-existing nit (admin UI audit actor still nil because settings
reads the wrong scope assign) does **not** block this release; treat as
follow-up.

### What was rechecked

Against commit `3927e30` on `main` (branch clean, matching `origin/main`), with
locked `phoenix_kit_publishing` **0.4.3** (issue reported against 0.4.4; the
relevant guard and `publish_version/4` path are present in 0.4.3):

1. **Root cause path** — `update_post/4` → `update_version_defaults/4` →
   `deferred_publish_status("published")` returns `nil`, so the status write is
   dropped (`posts.ex:1337`). `update_post` still returns `{:ok, post}`.
   Publishing's public path only serves posts with a non-nil
   `active_version_uuid` (`PublishingPost.published?/1`, draft gate at
   `post_rendering.ex:60`). Confirmed.
2. **Publishing's intended publish API** — `Versions.publish_version/4`
   atomically sets version status + `active_version_uuid`
   (`versions.ex:334-345`). Facade delegates at `publishing.ex:159`. Confirmed.
3. **Fix matches Publishing admin** — Legal now mirrors
   `Web.Listing.apply_status_change/4:951-956`
   (`publish_version(group, uuid, post[:version] || 1, actor_uuid: …)`). Same
   version-resolution and actor-key conventions.
4. **Return contract** — `Web.Settings.handle_event("publish_page", …)` matches
   `{:ok, _post}` / `{:error, reason}`. Re-read after `:ok` preserves that;
   bare `:ok` would have raised `CaseClauseError`. Correct.
5. **Blast radius** — only other `"status"` writes in `legal.ex` are
   `"draft"` (create/set-language paths). Grep of `lib/` shows no other
   `"published"` status writes. Sweep is sufficient for this package.
6. **Version resolution** — `read_post/2` with `version = nil` reads the
   **latest** version (`posts.ex:256-257`). Legal regenerate updates content
   in place on the existing version (`update_existing_legal_post/5` does not
   call `create_new_version`). So `post[:version]` is the right default for
   "publish what generate just wrote". An explicit `:version` opt is fine for
   advanced callers. Current/latest is correct here; max(available_versions) is
   the same value when regenerate does not fork versions.
7. **Partial-failure trade** — prefer current behaviour (`{:error, _}` if
   re-read fails after a successful publish). Success-with-stale-map would
   reintroduce "UI says published, listing state wrong". Rare failure mode;
   admin flash of error after a real publish is recoverable (refresh shows
   published). Acceptable.
8. **`@compile {:no_warn_undefined, …}`** — `publish_version/4` present; compile
   with `--warnings-as-errors` is clean via the suite path.

### Gates re-run

| Check | Result |
|-------|--------|
| `mix test` | 38 tests, 0 failures |
| Compile (via test path) | clean |

### Reviewer Q&A (answers to Claude's open questions)

| Question | Answer |
|----------|--------|
| Version choice: `post[:version]` vs max? | **Keep `post[:version]`.** Equals latest; regenerate mutates that version. |
| Partial failure: re-read error after publish? | **Keep `{:error, _}`.** Prefer honest failure over success-with-stale map. |
| Blast radius beyond `legal.ex`? | **Clean.** No other `"published"` status writes under `lib/`. |
| Stale `~> 1.7.170` in moduledoc? | **Optional docs fix** in this release if convenient; not behavioural. Non-blocking. |
| Integration harness from publishing? | **Not required for 0.1.9.** Borrowing `:integration` later is nice-to-have, not a release gate. |

### Related pre-existing issue (not introduced by this fix)

`Web.Settings` still passes `scope: socket.assigns[:current_scope]` for generate
and publish. PhoenixKit mounts **`phoenix_kit_current_scope`** (see
`Users.Auth` on_mount and every core LiveView). Publishing's own
`Shared.actor_uuid_from_socket/1` only reads that key.

Consequence: even with correct `actor_uuid/1` mapping in `legal.ex`, the admin
"Publish" button still records a **nil actor** in the activity log, because the
wrong assign is read. Pre-existed for generate/update audit as well. The
CHANGELOG claim *"The audit trail now records the acting user"* is true for
callers that pass a real scope with `user.uuid`; it is **not** true for the
admin button until settings reads `phoenix_kit_current_scope`.

Suggested follow-up (0.1.10 or same release if desired — **not required for #11**):

```elixir
scope: socket.assigns[:phoenix_kit_current_scope]
```

in all three `settings.ex` call sites (`generate_page`, `publish_page`,
`generate_all_pages`). Optional: prefer
`Publishing.Shared.actor_uuid_from_socket(socket)` at the LiveView boundary.

### Why the 0.1.7 recheck missed this

The earlier independent recheck
([2026-07-25-legal-public-pages-404.md](2026-07-25-legal-public-pages-404.md))
validated the **routing** causal chain only: reservation → no renderer → 404.
It explicitly left live-host smoke as "still not verified", and treated
"pages left in draft" as a **user/ops** residual (upgrade guide wording), not
as a broken code path.

What that review should have done and did not:

1. **Walk the full public-reachability path end-to-end in code**, not just the
   router. After confirming Publishing can serve `/legal`, the next question is
   "how does Legal mark a page published?" — that leads straight to
   `publish_page/2` and the `update_post(…, %{"status" => "published"})` call.
2. **Trust but verify cross-package write contracts.** Publishing's
   `deferred_publish_status/1` is a deliberate silent drop; any client still
   using the pre-M4 "set status" pattern is a landmine. The recheck read
   Publishing for *dispatch* and *draft gate*, not for *how publish is written*.
3. **The recommended smoke would have caught it.** The recheck itself said:
   *"enable Legal, publish at least one page, curl expect 200"*. That smoke was
   not run. The issue reporter effectively ran it and found the second defect.
4. **Scope narrowness.** The task was framed as rechecking Claude's *routing*
   fix report. Confirming that report's claims is necessary but not sufficient
   when the user-facing symptom ("`/legal` 404") has **stacked** causes. After a
   routing fix, residual same-symptom failures need a second pass over content
   lifecycle (generate → publish → active_version → dispatch).

Lesson for next recheck of a production 404: verify **every hop** from admin
action to public response, not only the hop the previous fix touched. Silent
success (`{:ok, _}` with no state change) is a class of bug that unit-free
library suites will not catch — either exercise a host DB path or assert the
client uses the correct Publishing API surface.

### Confirmation summary

- **Problem statement:** correct.
- **Causal chain** (status write dropped → no active version → public 404 +
  success flash): correct.
- **Chosen fix** (`publish_version/4` + re-read + actor mapping): correct and
  aligned with Publishing's own admin. **No further code changes requested.**
- **Version default / return contract / blast radius:** sound as Claude wrote them.
- **Known gap (no DB test):** acknowledged; acceptable for this package's
  DB-free suite; do not add a brittle source-string test.
- **Outstanding for hosts:** ship **0.1.9** (tag, GitHub release, Hex); then
  re-publish each legal page once. Optional later: fix settings scope assign so
  admin audit actor is real; optional docs: moduledoc `~> 1.7.170` → floor.
