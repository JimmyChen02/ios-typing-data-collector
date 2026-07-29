# 2026-07-29 — SymSpell language-model replacement

## Goal
Remove the Lexiteria-derived AOSP dictionary before redistribution and retain a
frozen, established, condition-independent English baseline with clear
downstream terms.

## Implementation
- Replaced the AOSP resource with SymSpell's official
  `frequency_dictionary_en_82_765.txt`, pinned to commit
  `c239062ae02961df18ab7da1671d01b4388204e0` and blob
  `3682dedea3400a7f3ff34d521844c9c0c427ed74`.
- Verified source SHA-256
  `c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b`.
- Added a deterministic generator for the 30,000 highest-frequency unique
  words and five frozen corrections for ambiguous common typos. The generated
  TSV SHA-256 is
  `843eeab1fec16df7699851a52cf97be8ec71e429cd6148fb0a21ce464a0293c8`.
- Switched decoder scoring to the base-10 logarithm of source corpus counts.
- Updated model provenance, tests, project resources, documentation, and
  third-party attribution.
- Removed the AOSP TSV and generator.

## Licensing
SymSpell documents the frequency dictionary as the intersection of Google Books
Ngram frequency data (CC BY 3.0) and SCOWL vocabulary data (permissive notice).
Attribution and source links are recorded in `THIRD_PARTY_NOTICES.md`.

## Verification
- Generic iOS Simulator app/extension build succeeded.
- Initial tests exposed a UTF-8 BOM attached to the first source word (`the`);
  the generator now decodes the source with `utf-8-sig`.
- Initial frequency-only behavior also preferred other one-edit words for
  several established autocorrection regressions. Added the five-entry frozen
  correction whitelist described above.
- All 18 `AdaptiveKeyboardCoreTests` passed on the iPhone 17 simulator.
