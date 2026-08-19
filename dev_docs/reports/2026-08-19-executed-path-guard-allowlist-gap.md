# The executed-path guard is a denylist over one macro, and Ecto's migration DSL has several

**2026-08-19** · Found in review of PR #18, after it merged. Recorded here rather
than fixed, because closing it is a decision — not a one-line patch — and this
report exists so that decision is made deliberately, not rediscovered from the gap.

## What the guard checks, and what it misses

`test/consent_logs_ownership_test.exs`, `neither direction executes SQL of its own`
(added in PR #18, `2369fc0`), asserts:

```elixir
refute source =~ ~r/execute\(/
assert length(Regex.scan(~r/&execute\/1/, source)) == 2
```

It was written to close one specific hole: a literal `execute("DROP TABLE ...")`
written into `up/1` past the pipe into `up_statements/1`, invisible to every guard
that reads the builder's *data* rather than the function that runs. That hole is
closed — the assertion above catches it.

But `PhoenixKit.Modules.Legal.Migrations` does `use Ecto.Migration`, which imports
the whole migration DSL by name, not just `execute/1`. None of the following touch
`execute(` and all three reach the database exactly as directly as the case the
guard was built for:

```elixir
drop(table(:phoenix_kit_consent_logs))
drop_if_exists(table(:phoenix_kit_consent_logs))
rename(table(:phoenix_kit_consent_logs), to: table(:phoenix_kit_consent_logs_old))
```

Each is `alter table(...) do remove ... end`'s neighbour, not an exhaustive list —
the DSL has more constructors than these three.

## Reproduced against `main`, not the branch that introduced the guard

Each appended to `up/1`, one at a time, after the pipe into `up_statements/1`:

```
drop(table(:phoenix_kit_consent_logs))                                    -> 18 tests, 0 failures
drop_if_exists(table(:phoenix_kit_consent_logs))                          -> 18 tests, 0 failures
rename(table(...), to: table(:phoenix_kit_consent_logs_old))              -> 18 tests, 0 failures
```

All eighteen guards in the file stay green in every case. The table this package
exists to protect — a GDPR/CCPA consent audit trail — is dropped, or renamed out
from under every query that reads it, and nothing reports it.

## Why the fix is not "add more regexes"

The guard added in `2369fc0` replaced a denylist (`refute stmt =~ DROP|TRUNCATE`)
with what looked like a stronger check, but the strength was illusory: it swapped
one denylist (forbidden SQL substrings) for another (one forbidden macro name).
Denylists over a language with imported identifiers are not finishable by adding
entries — Ecto's migration DSL alone has `drop`, `drop_if_exists`, `rename`, `alter`
with `remove`, and raw `execute` all reaching the adapter through different call
sites, and nothing stops a sixth arriving in a future Ecto release.

The form that closes this is the same one already proven in this file for a
different part of the same problem: `up/1 emits exactly these operations and no
others` (`35b3ec4`) does not ask "does this avoid the forbidden verbs" — it asks
"is this exactly the allowed set", built from `up_statements/1`'s own data. Nothing
absent from that set can pass, regardless of how it is spelled, because the
comparison is equality, not exclusion.

That test cannot see statements executed outside `up_statements/1`, which is
exactly the gap `2369fc0` exists to close — so the two are not redundant, they
guard different surfaces. What is missing is applying the *allowlist* shape to the
surface `2369fc0` guards: what actually reaches the adapter, not what the source
text looks like.

## What closing it for real would need

A source-text regex cannot express "no macro outside this allowed set was called" —
`use Ecto.Migration`, aliasing, and multi-line calls all defeat a text scan that
tries. The honest version runs `up/1` and `down/1` through a real migration process
(a stub `Ecto.Adapters.SQL.Sandbox` repo, or `Ecto.Migrator` against a scratch
database, as `test/scripts/verify_consent_logs_migration.exs` already does for the
DDL shape) and asserts the sequence of Ecto commands collected during that run
against an allowlist — `{:create, ...}`, `{:create_if_not_exists, ...}`, and the
single `COMMENT ON TABLE` `execute`, nothing else. That observes the executed path
directly instead of inferring it from source text, and it is immune to every
spelling in the DSL at once, including ones that do not exist yet.

This suite currently has no such runner and no scratch-database wiring for a fast
unit test. Building one is a real decision: it would be the first test in this file
that talks to a database, which changes what "run the suite" costs and requires.
Whether that cost is worth closing this specific gap, or whether the source-text
check should simply be widened to the DSL's other destructive macros as a cheaper
partial mitigation, is not decided here.
