<!--
SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
SPDX-License-Identifier: GPL-3.0-only
-->

# Prose quality configuration

This directory is the source of truth for spelling, link, and prose checks.
Run each command from the repository root.

```sh
lua tools/lint/spell/dictionary/generate.lua --check
npx --yes cspell lint --config tools/lint/spell/cspell/cspell.jsonc .
codespell --config tools/lint/spell/codespell/.codespellrc .
typos --config tools/lint/spell/typos/typos.toml .
lychee --config tools/lint/spell/lychee/lychee.toml .
vale --config tools/lint/spell/vale/.vale.ini .
```

## Canonical vocabulary

The reviewed source vocabulary lives under `dictionary`, with one term per
line and categories for acronyms, C APIs, C terminology, project terminology,
and proper names. Add a recurring domain term to the narrowest category. Fix a
real spelling error in its source document instead of adding it to the
vocabulary.

The generator combines the category files into `dictionary/coil-words.txt`.
CSpell and codespell consume this central word list directly. The other tools
require native adapters, generated with:

```sh
lua tools/lint/spell/dictionary/generate.lua
```

The generator creates the central word list and Vale vocabulary, and updates
the generated sections of the typos word table and Vale acronym rules. It
rejects duplicate, unsorted, or malformed source entries. CI runs `--check` so
a canonical vocabulary change cannot leave stale adapters behind.

Do not edit generated content by hand. Do not use document-wide spelling or
acronym suppressions. A genuinely document-specific term may use a narrowly
scoped inline directive, but recurring technical language belongs in the
canonical vocabulary.

## Vale policy

The broad `Coil` style contains spelling, anti-slop, and scientific rules. Its
base rules cover terminology, evidence, units, acronyms, and sentence mechanics.
Its anti-slop rules reject predictable filler and formulaic structures. Its
scientific rules cover claims, statistics, reproducibility, and article
conventions.

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

The C language style guide and pitfall catalog are normative references rather
than narrative articles. They use the focused `CoilSpelling` style, which keeps
spelling and acronym validation active across the complete documents without
applying narrative-prose heuristics to rule tables and compact requirements.

Use Vale's inline configuration comments only for a justified, isolated
exception. Limit the suppression to one rule and the smallest relevant
passage.

The phrase lists and structural guidance live under `vale/references`. The
article template, delivery checklist, and manual 50-point rubric live in
`vale/references/scientific-writing.md`.

<!-- EOF -->
