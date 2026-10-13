# PR #25 follow-up — 2026-10-13

Claude's two fixes in `b232107` remain: fresh hidden-list/fingerprint reads for
the policy alert, and validation of keys before hiding collection entries.
See [Claude's review](CLAUDE_REVIEW.md).

The second review fixed origin scheme validation, asynchronous consent races,
immediate withdrawal notifications, cross-tab reloads, undelivered choices
under clock skew, expired in-memory grants, discovery failure/timeout handling,
hot-path reader fallbacks, and repeated hook listeners. See
[Codex's review](CODEX_REVIEW.md) for triggers and validation.

Claude's clock-skew and repeated-listener findings are resolved. Duplicate
purpose gathering in core, global language fingerprint tracking, and the
unchanged-confirmation lifetime remain documented improvements.

The final checks pass: 345 Elixir tests including integration, 13 JavaScript
behavior tests, a Chromium host-page check, and `mix precommit`.
No version bump, push or publication is included.
