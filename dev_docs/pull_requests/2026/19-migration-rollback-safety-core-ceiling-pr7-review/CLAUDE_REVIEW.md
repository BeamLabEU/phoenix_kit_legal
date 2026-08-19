# PR #19 — Fix a migration rollback data-safety bug, widen core version ceiling, land PR #7's review

**Author:** timujeen · **Branch:** (direct to main) · **Reviewed:** 2026-08-19

Landed as `fb79f80`, five squashed commits by subject: commit the PR #7 review
(untracked since May), audit the module-migration version protocol, widen the
core dependency range, and fix the rollback/version-tracking bug the audit
found. The actual diff against `main` is three files —
`AGENTS.md`, `lib/phoenix_kit_legal.ex` (moduledoc, 6 lines), and a new report
`dev_docs/reports/2026-08-10-consent-logs-version-protocol-audit.md` — because
most of the commit-message narrative describes work that had already reached
`main` by other paths before this merge landed (the PR #7 review file is
`ada8ab2`, a separate prior commit; the migration chain's version-storage-via-
`COMMENT` and non-destructive `down/1` already exist in
`lib/phoenix_kit_legal/migrations.ex`, introduced whole by `98b4543`/PR #16
before this PR's audit commit). Worth flagging as read, not as a defect: the
commit body narrates fixes as if landing them here, but git history shows the
fix predates the audit that describes finding it — the value delivered by
*this* merge is the doc/moduledoc diff actually applied, not the code fixes
its message walks through.

## Verified independently, not taken on the commit message's word

| Claim | Checked against | Result |
|---|---|---|
| `phoenix_kit` dependency widened from `~> 1.7.227` to a range dropping the incidental `< 1.8.0` ceiling | `mix.exs:69` | ✓ `{:phoenix_kit, "~> 2.0"}` — satisfies the `>= 1.7.227` floor the moduledoc explains |
| `down/1` "unstamps the marker; NEVER drops the table" | `lib/phoenix_kit_legal/migrations.ex:112-119,178-187` | ✓ `down_statements/2` only ever emits `COMMENT ON TABLE ... IS NULL` or `IS 'pkl_schema:<target>'` — no `DROP`/`TRUNCATE`/`DELETE` in either branch |
| Version is read from a `pkl_schema:<N>` table comment, not inferred from table existence | `migrated_version_runtime/1`, `migrations.ex:81-101` | ✓ queries `pg_description` for the marker; a marker-less table reads as `0`, matching the moduledoc |
| `lib/phoenix_kit_legal.ex` moduledoc's `~> 2.0` dependency note matches the actual `mix.exs` pin and the AGENTS.md "Consent Config Endpoint Contract" section it's said to mirror | `AGENTS.md:162-190` | ✓ consistent — both state the 1.7.227 floor is the true minimum and 2.0 is higher than required, not evidence the floor moved |
| `Version.match?/2` claims in the commit body (`1.7.226 false, 1.7.227 true, 1.8.0 true, 2.4.1 true, 3.0.0 false` for `>= 1.7.227 and < 3.0.0`) | — | Not re-verified; moot, since the range actually shipped in `mix.exs` (`~> 2.0`) is narrower than what the commit body computed, and is itself correct per `Version.match?/2` semantics |

## Findings

None requiring a fix. Every factual claim in the shipped diff (AGENTS.md,
`phoenix_kit_legal.ex` moduledoc) checks out against the current code.

**Documentation nit (not fixed):** the commit message's per-step narrative
("Store the schema version instead of inferring it, and stop dropping on
rollback") reads as describing new work performed in this PR, but the
mechanism it describes was already live in `main` via PR #16 before this PR's
own audit commit. Anyone reading `git log` rather than diffing against `main`
directly could reasonably think this PR shipped a rollback-safety fix that it
did not — it shipped the write-up. Not a code or doc-content defect, and not
worth a follow-up commit to re-explain history; recorded here so the next
reviewer isn't caught by the same mismatch between message and diff.

## Verification

- `mix test` — 67 tests, 0 failures.
- `mix precommit` — clean (format, compile --warnings-as-errors, credo --strict, dialyzer).
- No functional `lib/` behavior changes; the one `lib/` edit is moduledoc prose.
