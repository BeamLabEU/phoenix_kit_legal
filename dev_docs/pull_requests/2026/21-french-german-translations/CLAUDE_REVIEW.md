# PR #21 — Add French and German translations

**Author:** timujinne · **Branch:** `feature/i18n-de-fr` · **Reviewed:** 2026-09-04

Completes `priv/gettext/{de,fr}/LC_MESSAGES/default.po` — settings UI,
cookie-consent widget, page titles. Translation catalogues plus the tests that
pin them; no schema.

> **Note on this document.** An earlier revision was written by the same party
> that prepared the PR and found nothing at BUG or IMPROVEMENT severity. An
> independent review then returned **FAIL** with two BUG-MEDIUM findings, a
> third semantic defect in the consent UI, several French corrections and a
> coverage gap — and corrected two factual claims of the earlier text. This
> revision records the independent findings and their resolution; the earlier
> conclusion is retracted.

## Verified — runtime-critical, all clean

A purpose-written `.po` parser was run over `de`, `fr`, `default.pot` and the
reference `ru`; results were then cross-checked against the compiled
`PhoenixKit.Modules.Legal.Gettext` beam.

| Check | Result |
|---|---|
| Entry count | 125 msgids + header in `de`, `fr`, the POT and `ru` — full parity. (The earlier revision said 126: it had counted the header's `msgid ""` as an entry.) |
| msgid set **and order** vs POT | byte-identical; `#:` references and `#,` flags identical on all 125 |
| **Interpolations `%{...}`** | 4 entries carry them (`%{reason}` ×3, `%{count}` ×1); all match in both languages — 0 mismatches |
| printf-style patterns | none exist in this domain |
| Plural forms | **none exist in this domain.** The `Plural-Forms` headers are correct (`(n != 1)` de, `(n > 1)` fr) but inert — the earlier revision presented them as evidence of care, which overstated their relevance |
| HTML / links inside strings | none — links are assembled in HEEx, not in msgids |
| Empty msgstr / fuzzy / obsolete / duplicates / msgctxt | 0 / 0 / 0 / 0 / 0 |
| Encoding | UTF-8, LF, trailing newline; header shape matches `et`/`en`/`ru` |
| Compiles and ships | both catalogues present in the built beam; `mix.exs` `files:` includes `priv` whole |
| **Colliding translations** (distinct msgids → one msgstr) | after the fixes below: **0 in de, 0 in fr** |

## Findings and resolution

### `BUG - MEDIUM` — "Required By" rendered as a deadline (de) — fixed

`Erforderlich bis` means "required until". The string heads a table column
whose cells render the compliance frameworks requiring each page — the HEEx
builds them into a variable literally named `required_by`. The column
announced a date and then listed regulators. Now `Gefordert durch`. French
already had it right (`Requis par`).

### `BUG - MEDIUM` — "Reg. No:" narrowed to the German commercial register (de) — fixed

`Handelsregisternr.:` labels `@company_info["registration_number"]`, a
jurisdiction-neutral field from Organization settings — wrong beside a French
SIREN, a UK company number or a US EIN. Now the neutral `Reg.-Nr.:`, matching
how the catalogue already abbreviates its neighbour (`VAT:` → `USt-IdNr.:`).
French was already neutral (`N° d'immatriculation :`).

### Ambiguous confirm button in the consent modal (de) — fixed

In the German consent modal the fourth cookie category read `Einstellungen`
and the confirm button directly beneath it read `Einstellungen speichern` —
the button appeared to save that one category rather than the whole choice.
Four distinct msgids had collapsed onto two strings. The category is now
`Präferenzen` and the button `Auswahl speichern`, which also frees
`Einstellungen speichern` for the unrelated admin *Save Settings* button.
French and Russian kept these apart from the start; German was the only
locale that did not.

### French renderings — fixed

The widget position labels were word-for-word calques (`Bas gauche`, …) and
now read as French does (`En bas à gauche`, …). `Legal Review Required` was
`Révision juridique requise` — a revision, not a review — and disagreed with
the neighbouring string that already says `Faites-les relire par un
professionnel du droit`; now `Relecture juridique requise`.

### `IMPROVEMENT - HIGH` — no test covered the new locales — fixed

`test/phoenix_kit_legal/i18n_test.exs` pinned translations by name for `ru`
and `et` only. `de` and `fr` now have mirror blocks (27 tests, up from 15),
extending the hardcoded list rather than replacing it with a dynamic sweep — a
sweep catches an emptied catalogue but not a wrong translation, and a loop over
an empty locale list passes vacuously.

One trap was avoided deliberately: `Marketing` translates to `Marketing` in
both languages, so asserting it would pass with the catalogue removed entirely
(Gettext falls back to the msgid). `de`/`fr` therefore pin three of the four
categories where `ru`/`et` pin four, and the test says so in a comment.
Mutation-proven: replacing `Rechtliches` in the catalogue fails exactly the
three tests bound to that msgid; restoring it returns 27/0.

### `IMPROVEMENT - MEDIUM` — no CHANGELOG entry, no `@version` bump — deliberately not done

Raised as a convention violation, and this repository does keep its CHANGELOG
down to single-bullet edits. Both are nonetheless left untouched here at the
repository owner's explicit instruction that version and changelog belong to
the maintainer. Flagged so the two conventions can be reconciled once rather
than re-litigated per PR.

### `NITPICK` — left for the maintainer

- `de` `USt-IdNr.:` narrows the generic `VAT:` (fr is neutral: `TVA :`).
- `de` `Richtlinie zur akzeptablen Nutzung` is a calque; `Nutzungsrichtlinie` is the accepted term.
- `de` introduces the abbreviation `(DSB)` once and never reuses it.
- `fr` bare `cadres` is ambiguous where the rest of the file says `cadres de conformité`.
- `fr` `les conditions` vs `Conditions d'utilisation`; both `fr` and `de` add a "déjà"/"bereits" absent from the source.
- `fr` `Essentiels` (plural) beside `Analytique`/`Marketing` (singular); the mix is mirrored in `de`.
- `fr` uses no non-breaking space before `:` / `?` anywhere — consistent throughout, so likely a choice.
- Outside this diff: generated document bodies do not go through gettext, so a French widget links to an English privacy policy. Pre-existing, not introduced here.

## Note for the maintainer

The branch's first commit is titled `i18n: add French and German translations`,
which does not use the `Add`/`Update`/`Fix`/`Remove`/`Merge` prefix. It was not
amended in place because that SHA is pinned in a downstream lockfile — worth
normalising on squash-merge.
