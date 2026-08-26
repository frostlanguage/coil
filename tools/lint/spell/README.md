<!--
SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
SPDX-License-Identifier: GPL-3.0-only
-->

# Prose quality configuration

This directory is the source of truth for spelling, link, and prose checks.
Run each command from the repository root.

```sh
npx --yes cspell lint --config tools/lint/spell/cspell/cspell.jsonc .
codespell --config tools/lint/spell/codespell/.codespellrc .
typos --config tools/lint/spell/typos/typos.toml .
lychee --config tools/lint/spell/lychee/lychee.toml .
vale --config tools/lint/spell/vale/.vale.ini .
```

`cspell/cspell-words.txt` contains project terminology shared by CSpell,
codespell, and the `Coil.Spelling` Vale rule. Keep one term per line. Prefer a
narrow, reviewed exception over disabling a checker for an entire file type.

## Vale policy

The single `Coil` style contains the spelling, anti-slop, and scientific rules.
Its base rules cover terminology, evidence, units, acronyms, and sentence
mechanics. Its anti-slop rules reject predictable filler and formulaic
structures. Its scientific rules cover claims, statistics, reproducibility,
and article conventions.

Files under `docs/articles`, `docs/papers`, and `docs/research` enable the
scientific mode. A file with a `.paper.md` suffix receives the same policy. Scientific
articles name authors or participants and omit second-person address.

The rules use three severity levels:

- `error` identifies objective defects, such as misspellings or missing spaces
  between values and units.
- `warning` identifies claims or constructions that require revision or
  supporting evidence.
- `suggestion` identifies sentences that benefit from human review but may be
  valid in context.

The style detects observable prose patterns and makes no inference about
whether a human or a model wrote the text. Its anti-slop rules target stock phrases,
promotional claims, vague references, unsupported attribution, and inflated
wording. The remaining rules improve technical precision through acronym
definitions, consistent units, concise sentences, and explicit actors.

Use Vale's inline configuration comments for a justified exception. Limit the
suppression to one rule and the smallest relevant passage.

The phrase lists and structural guidance live under `vale/references`. The
article template, delivery checklist, and manual 50-point rubric live in
`vale/references/scientific-writing.md`.

<!-- EOF -->
