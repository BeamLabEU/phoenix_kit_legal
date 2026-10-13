# Follow-up — PR #12 (remove the consent-config controller)

Findings from `CLAUDE_REVIEW.md`, re-checked against the code on 2026-10-13.

## Fixed (pre-existing)

- ~~BUG - CRITICAL: 500 against a core that does not own the route~~ — core
  ships `PhoenixKitWeb.Controllers.ConsentConfig` and declares the route
  unconditionally; this package has no such controller.
- ~~BUG - HIGH: dependency floor~~ — `mix.exs` pins `{:phoenix_kit, "~> 2.0"}`,
  above the 1.7.227 floor.

## Fixed (Batch 1 — 2026-10-13)

- ~~BUG - MEDIUM: docs still describe the removed controller~~ — the two
  stale spots that were left: `README.md` said the floor in `mix.exs` was
  `~> 1.7.227` (it is `~> 2.0`), and the `mix.exs` comment named core's
  controller `…ConsentConfigController` and pointed at an AGENTS.md section
  that no longer exists. Both reworded.

## Skipped (with rationale)

- NITPICK: the 2026-04-19 spec under `dev_docs/superpowers/specs/` still
  mentions the removed controller. It is a dated design record, and the review
  itself said to leave it.

## Files touched

| File | Change |
|---|---|
| `README.md` | Core floor sentence matches the pin |
| `mix.exs` | Comment names core's controller and the right AGENTS.md section |

## Verification

`mix precommit` and `mix test` — see the PR that carries this file.

## Open

None.
