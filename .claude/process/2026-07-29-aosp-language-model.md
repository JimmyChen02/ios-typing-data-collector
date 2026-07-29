# 2026-07-29 — Pinned AOSP LatinIME language model

> Superseded the same day by the SymSpell model. AOSP's NOTICE says its
> Lexiteria dictionaries are “Used by permission,” which does not clearly grant
> downstream redistribution of a transformed standalone dictionary. The AOSP
> artifact and generator were removed before commit.

## Goal
Replace the handcrafted keyboard vocabulary and demo typo table with a
reproducible, established offline model that cannot vary between classic and
Gaussian study conditions.

## Implementation
- Pinned official AOSP LatinIME commit
  `127336e9f29d69607eab55982324b210279ae8c5`.
- Downloaded `dictionaries/en_US_wordlist.combined.gz` and verified SHA-256
  `0f78dd455b532be169a23f233227b811fabced4b5bd7fc9c40cc05839793bcbd`.
- Added `scripts/generate_aosp_english_model.py`. It refuses changed source
  bytes, retains 30,073 unigrams with AOSP frequency >= 80, and includes 46
  official `not_a_word` whitelist corrections.
- Replaced generated Swift dictionaries / JSON with the compact
  `TypingResearchShared/aosp_en_us_v54_f80.tsv` resource.
- Reworked `LocalLanguageDecoder` to use AOSP frequency ranking, prefix
  completion, bounded one-edit correction, adjacent transposition handling,
  and official whitelist replacements.
- Removed handcrafted context rules. The public AOSP artifact has no
  contextual n-grams, so an empty current word uses global unigram ranking.
- Excluded touch proximity and user learning to keep language scoring
  condition-independent.
- Added model provenance, load status, candidate scores, and decode latency to
  language-model events.

## Errors and fixes
- The documented `venv/bin/python` was absent, so the stdlib-only generator was
  run with the system `python3`.
- The first build destination (`iPhone 16`) was unavailable. Retried on the
  available iPhone 17 simulator.
- The first test compile could not directly resolve the new metadata type from
  the test module. Exposed the provenance checks through
  `LocalLanguageDecoder`, then test compilation succeeded.
- Simulator test execution stalled after build/validation both before and
  after explicitly booting the simulator. Both hung runs were terminated.
- Later working-tree gesture/event-schema additions had incomplete delegate
  and logging call sites. Fixed protocol conformance, optional text-field
  traits, correction linkage, emoji gesture exclusivity, and gesture arguments
  until the full app/extension and test bundle compiled again.

## Outcome
- App and keyboard extension build succeeded after runtime artifact checksum
  validation was enabled.
- Model resource is present in the app, extension, and test bundles.
- All changed Swift files have no IDE diagnostics.
- `build-for-testing` succeeded. XCTest execution still did not start because
  the simulator test runner stalled.
