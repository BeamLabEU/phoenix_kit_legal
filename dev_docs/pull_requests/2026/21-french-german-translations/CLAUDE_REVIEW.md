# PR #21 — Add French and German translations

**Author:** timujinne · **Branch:** `feature/i18n-de-fr` · **Reviewed:** 2026-09-04

Completes `priv/gettext/{de,fr}/LC_MESSAGES/default.po` — settings UI,
cookie-consent widget, page titles. Two files, no code, no schema.

## Verified, claim by claim

| Claim | Result |
|---|---|
| Full parity with the source template | ✓ 126 msgids in each of `de` and `fr`; `priv/gettext/default.pot` has 126 |
| Matches the completeness of the existing locales | ✓ `ru` also carries 126 — the stated bar is met exactly, not approximately |
| Nothing left provisional | ✓ 0 `#, fuzzy` entries in either file |
| No silently untranslated strings | ✓ the only empty `msgstr ""` in each file is the catalogue header |
| Plural forms are per-language, not copied | ✓ `nplurals=2; plural=(n != 1);` for German and `nplurals=2; plural=(n > 1);` for French — these genuinely differ, and both are right |
| The catalogues actually compile and serve | ✓ a host app pinned to this branch builds and renders `/legal` and `/legal/privacy-policy` in both languages on a live three-domain install |

Spot-checked domain wording rather than only counting entries: `Legal` renders
as `Rechtliches` (de) and `Mentions légales` (fr) — the latter is the correct
French legal-notice term, not a literal rendering of the English word.

## Findings

None at BUG or IMPROVEMENT severity.

**NITPICK** — the branch's single commit is titled `i18n: add French and German
translations`, which does not use the `Add`/`Update`/`Fix`/`Remove`/`Merge`
prefix this repository asks for. It was not amended in place because the commit
SHA is pinned in a downstream lockfile and rewriting it would strand that
resolution mid-flight; worth normalising on squash-merge instead.

## Not done here

`@version` and `CHANGELOG.md` are deliberately left untouched for the
maintainer.
