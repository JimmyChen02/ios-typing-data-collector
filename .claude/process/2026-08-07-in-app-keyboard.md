# 2026-08-07 — In-app keyboard migration

**Context:** Preserve the iOS-style custom keyboard and main study UI while
removing the system keyboard extension and all server transfer requirements.

**Changes:** Added one app-hosted keyboard for classic and Gaussian sessions.
Classic mode uses fixed rectangles; Gaussian mode uses the same visual layout
with `GaussianKeyModel` letter routing. The local language model, candidate bar,
autocorrection, shift, symbols, delete repeat, touch sliding, and key popups are
retained. `TrialView` converts keyboard edits into the existing ordered study
events.

**Data transfer:** Removed the dormant HTTP `BackendClient`. Data persists in
SwiftData/Documents and is exported with the existing iOS share sheet. Raw CSV
rows now include text after the edit, edit source and lineage, original/emitted
text, and JSON-encoded touch samples with coordinates, radius, force, timing,
and LM candidate targets.

**Verification:** A fresh generic iOS Simulator build and `build-for-testing`
both succeeded with `CODE_SIGNING_ALLOWED=NO`. `git diff --check` passed.

**Deferred:** Emoji, one-handed layout, trackpad cursor movement, and dictation
are not included in the in-app keyboard.

---

## Follow-up — LM provenance + iOS underlines (same day)

**LM:** Already off-the-shelf SymSpell English 30k frequency lexicon
(`TypingResearchShared/symspell_en_30k.tsv`, id `symspell-en-30k-c239062`). No
custom neural LM. Spell marking uses Apple `UITextChecker` (also off-the-shelf).

**UI:** `AnnotatedTypingCanvas` in the keyboard playground draws red dotted
underlines on completed misspellings and a temporary grey underline on the
latest autocorrected word. Tap the grey mark to restore the original typed text
and log `correctionReversion`. Grey mark clears when the user continues typing.

**Build:** `/tmp/TypingResearchUnderlines` generic Simulator build succeeded.

---

## Follow-up — cursor / Space trackpad / QuickType pill (same day)

**Cursor:** `AnnotatedTypingCanvas` is a first-responder UITextView with empty
`inputView` (system keyboard suppressed) so the native caret is visible. Tap in
text to place caret; keyboard insert/delete/replace are caret-aware.

**Space trackpad:** Hold Space ~0.45s (or slide while holding) → trackpad mode,
keys dim, finger moves caret; release does not insert a space.

**QuickType emphasis:** Pending autocorrect center candidate draws as a rounded
gray capsule with semibold text (`“typed”` | correction | alt), restoring the
extension-era presentation.

**Build:** `/tmp/TRCursor4` **BUILD SUCCEEDED**.
