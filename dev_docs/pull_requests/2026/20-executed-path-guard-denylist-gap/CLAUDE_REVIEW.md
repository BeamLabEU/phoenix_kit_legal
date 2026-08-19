# PR #20 — Record that the executed-path guard is a denylist over one macro

**Author:** timujeen · **Branch:** (direct to main) · **Reviewed:** 2026-08-19

Landed as `a954968`. Documentation only — `AGENTS.md` plus a new report,
`dev_docs/reports/2026-08-19-executed-path-guard-allowlist-gap.md`. Records a
gap found while reviewing PR #18 (after it merged): `neither direction
executes SQL of its own` in `test/consent_logs_ownership_test.exs` closes one
specific hole (a literal `execute("DROP TABLE ...")` appended past the pipe
into `up_statements/1`) by asserting the source contains no `execute(` beyond
the two piped calls — but `use Ecto.Migration` imports the whole migration
DSL, and `drop(...)`, `drop_if_exists(...)`, and `rename(...)` reach the
database exactly as directly without ever touching `execute(`. Deliberately
not fixed here — the report argues the fix isn't "add more regexes" (another
denylist) but a real allowlist over the *executed* path, which needs a
migration runner this suite doesn't have, and that's recorded as a decision
for someone to make rather than made unilaterally in a docs PR.

## Verified independently, not taken on the report's word

- Read the actual guard, `test/consent_logs_ownership_test.exs:257-269`:
  `refute source =~ ~r/execute\(/` plus a count-of-2 check on `&execute/1`.
  Confirmed it is a source-text regex over `lib/phoenix_kit_legal/migrations.ex`,
  not a runtime trace — so it can only ever see what's spelled `execute(` in
  that file. ✓ matches the report's description.
- Confirmed `up/1` (`migrations.ex:104-109`) is exactly
  `opts |> validated_prefix() |> up_statements() |> Enum.each(&execute/1)` —
  the only statements that reach the database today are the ones in
  `up_statements/1`, so the gap is theoretical against the *current* file, not
  a live hole. The report says the same (reproduced by manually appending the
  three macros, not by finding them already present).
- Checked the three example macros the report cites
  (`drop(table(...))`, `drop_if_exists(table(...))`,
  `rename(table(...), to: table(...))`) are genuine `Ecto.Migration` macros
  imported by `use Ecto.Migration` and none contain the substring `execute(`
  in their own call syntax — the regex genuinely cannot distinguish "not
  called" from "called via a different macro name." ✓
- Cross-checked the report's framing against `AGENTS.md`'s prior wording
  (pre-PR, via `git show fb79f80~1:AGENTS.md` — actually the state before
  `a954968`): the "Never emit DROP..." bullet did read as a flat claim that
  the test suite pins the rule, with no caveat about which macros the guard
  actually covers. The PR's rewording to state partial coverage explicitly is
  accurate, not an overcorrection — the allowlist test (`up/1 emits exactly
  these operations`) covers the *built* statements fully; only the *executed*
  path has the gap.

## Findings

None. The report is accurate, appropriately scoped (records a decision point
rather than making a unilateral call on test infrastructure cost), and the
AGENTS.md wording change it ships correctly narrows an overstated claim rather
than removing a true one.

## Verification

- `mix test` — 67 tests, 0 failures (unaffected by this PR by construction —
  no `lib/` or `test/` changes).
- `mix precommit` — clean.
- No functional or public-behavior changes.
