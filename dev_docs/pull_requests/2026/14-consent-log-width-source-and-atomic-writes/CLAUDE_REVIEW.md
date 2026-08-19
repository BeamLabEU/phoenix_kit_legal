# PR #14 — Make core's widths a single source, guard the producer, and make consent logging atomic

- **Branch:** `fix/consent-log-width-source-and-atomic-writes`
- **Author:** timujeen
- **Merge:** `a77fbc7` (commit `ef48e84`)
- **Reviewer:** Claude Opus 5
- **Date:** 2026-08-10
- **Verdict:** PASS with fixes — the three changes are correct and land where the
  commit says they land. Four defects found around them, two of which falsify
  claims the PR's own documentation makes. All fixed here.

## What the PR did

1. Moved core's five `varchar` widths out of literals inside
   `validate_column_widths/1` into `ConsentLog.column_widths/0`, and derived the
   validations from that map.
2. Added a parity test that reads `PhoenixKit.Migrations.ExpectedSchema` and
   asserts both directions — every width this package validates is core's, and no
   varchar column core declares goes unvalidated.
3. Guarded `Legal.update_policy_version/1` against a version wider than
   `consent_version`, reading the limit from `column_widths/0`.
4. Wrapped `log_consents/2` in a transaction so a rejected entry commits none of
   the others.

All four are right. The parity test in particular is the correct shape: it reads
core's manifest rather than trusting a comment, guards against a vacuous pass, and
compares on strings so a column core adds reports as a failure rather than an
`ArgumentError` from the test's own setup. Nothing below argues with the PR's
direction — the findings are gaps in the guarantees it claims to establish.

---

## BUG - HIGH: `get_auto_policy_version/0` has never worked; the PR's docs assume it does

`list_generated_pages/0` built each page's `updated_at` from
`get_in(post, [:metadata, :updated_at])` (`legal.ex:1024`). **Publishing has no
such key.** Its post map carries the content timestamp at the *top* level as
`:content_updated_at`; `DBStorage.Mapper.build_metadata/5` and
`build_listing_metadata/5` never put an `:updated_at` into `:metadata`. Verified
by calling Publishing's mapper directly:

```
top keys:      [..., :content, :content_updated_at, :metadata, ...]
metadata keys: [:status, :version, :description, :title, :published_at, :tags, ...]
content_updated_at: ~N[2026-08-10 22:03:27.123456]
metadata.updated_at: nil
```

So the field was permanently `nil`, the `Enum.reject(&is_nil/1)` in
`get_auto_policy_version/0` always emptied the list, and the function always fell
through to `get_policy_version()`.

Two consequences, in increasing order of seriousness:

1. **The PR's documentation is inverted.** The new `@doc` on
   `update_policy_version/1` — and the commit message, and the AGENTS.md text —
   argue that the manual setting is the active version "only while no
   cookie-policy or privacy-policy page is published", and that the window is
   therefore "narrower than *always*". In the shipped code the window *is*
   always. That doesn't weaken the guard the PR added; it makes it the only thing
   standing between an admin's typo and a dead audit trail, which is a stronger
   claim than the one the doc makes.
2. **The feature the version exists for was dead.** `get_policy_version/0`'s own
   doc says "Changing this version will prompt users to re-consent." Because the
   auto path never fired and the admin LiveView exposes no input for the manual
   setting (no `handle_event` writes `legal_policy_version`), the consent version
   was pinned at the `"1.0"` default forever. Updating a privacy policy did not
   re-prompt a single visitor for consent — a GDPR-relevant behaviour, silently
   absent.

Pre-existing, not introduced by this PR. It is reported here because the PR's
central premise is a claim about this code path, and the skill's rule is to verify
the trigger against the emitter rather than the description.

**Fixed:** read `post[:content_updated_at]` first, keeping the metadata read as a
fallback for older Publishing releases.
`test/phoenix_kit_legal/policy_version_test.exs` pins the key against Publishing's
*own mapper* — a hand-written fixture would be a second copy free to drift, which
is the failure mode this package has been unwinding all year.

## BUG - MEDIUM: the width checks count graphemes; Postgres counts code points

Both new guards count the wrong unit.

- `validate_length/3` defaults to `count: :graphemes`.
- `String.length/1`, in `update_policy_version/1`, counts graphemes.
- `varchar(n)` in Postgres limits **characters** — code points.

They agree on ASCII and diverge on anything with a combining mark or a ZWJ
sequence. Measured:

```
String.duplicate("é", 20)   # e + U+0301
graphemes: 20   codepoints: 40   bytes: 60
validate_length(max: 20)                     → valid? true
validate_length(max: 20, count: :codepoints) → valid? false
```

So a 20-grapheme `consent_version` passes the changeset, passes the producer
guard, reaches Postgres at 40 characters, and comes back as the raw
`Postgrex.Error` on a varchar overflow — precisely the outcome the comment above
`validate_column_widths/1` says these validations exist to replace, and
`create/1` is public API, so the caller still has no way to check first.

`consent_version` is the reachable field: it is free-form host- or admin-supplied
text. The others are ASCII by construction (a SHA256 hex digest, an IP, a
whitelisted type), which is why this had not surfaced.

**Fixed:** `count: :codepoints` in `validate_column_widths/1`;
`length(String.codepoints(version))` in `update_policy_version/1`.
`column_widths/0`'s doc now states the unit, since its whole purpose is to be read
by producers — and a producer that reads the right number in the wrong unit is
back to the drift the map was created to end.

## BUG - MEDIUM: `format_version_date/1` could emit a 26-character version

The binary clause returned the string verbatim when `DateTime.from_iso8601/1`
failed:

```elixir
{:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
_ -> datetime
```

An offset-less ISO8601 timestamp with microseconds — `"2026-08-10T22:03:27.123456"`,
what `Jason` produces for a `NaiveDateTime`, and a plausible shape for a
JSONB-decoded timestamp — does not parse and is 26 characters. That value becomes
`consent_version`.

This is the same defect the PR fixed at `update_policy_version/1`, one function
away, on the path the PR describes as the one that "cannot overflow the column".
With finding #1 fixed the live input here is a struct, so the clause is now
defensive — but it is the fallback for exactly the unexpected shape that would
justify keeping it.

**Fixed:** falls back to `get_policy_version/0`, which is width-guarded, matching
what the `_` catch-all clause already did.

## IMPROVEMENT - MEDIUM: `log_consents/2`'s documented return does not hold inside a caller's transaction

`repo().rollback/1` in a nested `transaction/1` is not scoped to the inner call.
Ecto nests without a savepoint, so for a host app that calls `log_consents/2`
inside its own `Repo.transaction`:

- the rollback aborts the **caller's** transaction along with the consent writes;
- `log_consents/2` never returns — `{:error, errors}` surfaces from the
  *outermost* `transaction/1`, not from the call the host made.

The commit says "Return shapes are deliberately unchanged". That is true at the
top level and not true one frame down, and `log_consents/2` is public API for host
apps — the only kind of caller that exists.

**Not changed, documented.** Aborting the caller's transaction when the consent
record cannot be written is defensible, and arguably the safer default for an
audit trail; silently degrading it to a savepoint would trade a loud failure for a
quiet one. What was wrong was that the behaviour was undocumented while the commit
message asserted the opposite. The `@doc` now carries an "Atomicity" section
stating it, and tells a caller who needs their own work to survive to run the
consent write outside their transaction.

## IMPROVEMENT - LOW: `insert_consents/2` keeps inserting after the first failure

`Enum.map` runs every insert even once one has failed, then rolls back all of it.
Wasted round-trips, and a latent hazard: if a failure ever arrives as a DB-level
`{:error, changeset}` rather than a raise — which needs a declared constraint —
every later insert in the now-aborted transaction fails too, and the returned
`errors` list becomes noise about the abort rather than the original cause.

**Not changed.** Not reachable today: the changeset declares no
`unique_constraint`/`foreign_key_constraint`, so every `{:error, _}` here is
validation-only and never touches the DB; a genuine DB error (a null byte in
`metadata`, an overflow past the width checks) raises and unwinds cleanly.
Halting on the first error would shrink the `errors` list to one element and break
the contract the PR deliberately preserved, and validating all changesets before
inserting any would add a second construction path alongside `create/1`. Both cost
more than the defect is worth. On record so the next constraint added to this
schema is a prompt to revisit it.

## NITPICK: AGENTS.md still restates the widths in prose

The new "Database Table" text points at the top-of-file warning — "the numbers are
listed in the warning at the top of this file" — which still spells out all five.
The single-source argument the PR makes for code applies to the doc: this is a
copy, and `test/consent_logs_ownership_test.exs` checks the map, not the prose.
Left alone; a doc that names the numbers once and is read by humans is worth more
than the drift risk, and the warning is the first thing anyone touching this table
reads.

---

## Verification

- `mix test` — 54 tests, 0 failures (51 before; 3 added).
- `mix format`, `mix credo --strict`, `mix compile --warnings-as-errors`,
  `mix dialyzer` via `mix precommit` — clean.
- Finding #1 confirmed by executing Publishing's `DBStorage.Mapper.to_post_map/6`
  and inspecting the emitted keys, not by reading it.
- Finding #2 confirmed by running both `validate_length/3` variants against a
  20-grapheme / 40-code-point string.

Per the repo's testing stance, no DB is involved; the new tests are pure
(Publishing's mapper is a pure function over structs, and
`update_policy_version/1` returns before reaching `Settings` on the rejection
path).
