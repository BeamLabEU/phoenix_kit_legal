# `publish_page/2` silently no-op'd — pages stayed drafts and 404'd

**Date:** 2026-07-25
**Repo:** `BeamLabEU/phoenix_kit_legal` (fix, 0.1.8 → 0.1.9)
**Issue:** [#11](https://github.com/BeamLabEU/phoenix_kit_legal/issues/11) — reported by @timujinne (Tymofii Shapovalov)
**Reported against:** `phoenix_kit` 1.7.211, `phoenix_kit_legal` 0.1.8, `phoenix_kit_publishing` 0.4.4
**Status:** fixed on `main`, **not released** — held for independent review
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
