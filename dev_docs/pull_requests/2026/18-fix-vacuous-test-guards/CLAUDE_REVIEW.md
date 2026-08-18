# PR #18 — Break every invariant guard in the module, entirely and partly; fix the five that stayed green

**Author:** timujinne · **Branch:** (direct to main) · **Reviewed:** 2026-08-18

Test-only PR. Applies the round-2/#17 rule — break each guarded source both
entirely and partly, and treat "still green" as a finding — to every other
check in `test/consent_logs_ownership_test.exs`,
`test/schema_prefix_conformance_test.exs`, and `test/phoenix_kit_legal/i18n_test.exs`.
Finds and fixes five checks that could not go red (`for`/`refute` over a list
that can be empty), a phrase-pinned Ecto message, a substring scan blind to
appended statements, an untested locale scope, and a check that read the
builder's data but never the function that actually executes it. No `lib/`
changes.

## Verified independently, not taken on the commit message's word

Every regex the PR adds to parse `up_statements/1`/`down_statements/2` was
cross-checked against the actual DDL in
`lib/phoenix_kit_legal/migrations.ex` rather than trusted from the diff:

| Check | Result |
|---|---|
| `operation/1`'s alternation (`CREATE UNIQUE INDEX` before `CREATE INDEX`, etc.) against all 9 `up_statements/1` entries | ✓ every statement maps to the expected `{verb, object}`, including the DO-block's `ADD CONSTRAINT` extraction |
| `@up_operations` (9 entries) against `up_statements/1`'s literal list | ✓ exact match, both `"public"` and `"legal_alt"` prefixes |
| `down_statements/2` full-text comparisons (4 cases: `public`/`legal_alt` × marker/unmarker) | ✓ match the builder verbatim |
| The two `~r/up_statements\(\)\s*\|>\s*Enum\.each\(&execute\/1\)/` / `down_statements(target)\|>...` source-text regexes | ✓ match `up/1`/`down/1`'s actual pipe chains |
| `refute source =~ ~r/execute\(/` doesn't false-positive on the module's own doc comments ("`up/1` **executes**...") | ✓ — "executes" has no `(` immediately after; only the two `&execute/1` captures exist in the file |
| `ConsentLog.column_widths().session_id == 64`, `.consent_version == 20` reachable from the new metadata assertions | ✓ |

Ran the actual suite rather than trusting the commit message's reported
counts:

- `mix test test/consent_logs_ownership_test.exs test/phoenix_kit_legal/i18n_test.exs test/schema_prefix_conformance_test.exs` — 35 tests, 0 failures.
- `mix test` (full suite) — 67 tests, 0 failures.
- `mix precommit` (format, compile --warnings-as-errors, deps.unlock --check-unused, hex.audit, credo --strict, dialyzer) — clean, exit 0.

## Findings

None. This is the same author's own audit of their prior test-hardening work,
each fix independently reproduced (before/after counts in the commit body) and
independently re-verified above by reading the source the new assertions
depend on rather than by re-running the author's own reproduction steps.

Worth flagging as read, not as a defect: the commit body's own "Remove the
last guard on a state the builder cannot reach" is the author catching that
three of *their own* emptiness guards from earlier in this same PR protect
states `up_statements/1`'s single list literal can't produce, and removing
them rather than leaving them as dead weight. That kind of self-correction
mid-PR is unusual and is why this review found nothing left to add.

## Verification

- `mix test` — 67 tests, 0 failures.
- `mix precommit` — clean, exit 0.
- No `lib/`, `priv/`, or public-behavior changes — nothing here affects the
  published package (test/ is excluded from the Hex `files:` list).
