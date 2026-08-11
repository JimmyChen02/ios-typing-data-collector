# In-app research keyboard

The app owns and displays an in-app iOS-style keyboard. Participants do not
install a keyboard extension, and there is no App Group, Supabase, or research
server requirement.

## Keyboard-first playground

`ParticipantSetupView` → **Open Keyboard** launches `KeyboardPlaygroundView`:
type freely, inspect the suggestion bar, and export a CSV of every edit. Use
this screen while locking touch feel and LM behavior.

## Device-adaptive sizing

`SystemKeyboardMetrics` sizes the keyboard per installed iPhone:

- **Letter keys are width-driven** (screen width → key width → height ≈ 1.32×),
  matching stock iOS proportions. Rows are not stretched to fill leftover height.
- Gaps/side insets scale by short-side class (SE → Pro Max).
- A one-shot system-keyboard probe (and any later system keyboard show) records
  exact chrome height; extra height is absorbed as bottom pad so key targets stay
  stable.

## Study flow

Timed trials embed the same `InAppResearchKeyboardView`. Gaussian / adaptive hit
routing is disabled for now — every session uses classic fixed rectangles.

Language-model behavior mirrors iOS QuickType more closely than autocomplete:
- **LM:** off-the-shelf SymSpell English 30k frequency lexicon
  (`symspell_en_30k.tsv`, id `symspell-en-30k-c239062`) via `LocalLanguageDecoder`.
  Not a custom neural model.
- The top bar shows up to three suggestions (typed literal stays visible; when a
  spelling correction is pending, the bar shows `“typed”` / correction / alternate).
- Tapping a suggestion applies it.
- Space applies autocorrect only for confident spelling typos, never for prefix
  completions (`hel` will not become `hello` on space).
- **Spell underlines (playground):** red dotted underlines use Apple’s
  `UITextChecker` on completed misspelled words. After LM autocorrect, a temporary
  grey underline marks the corrected word; tap it to revert (`correctionReversion`).
- **Cursor:** playground shows a blinking caret; tap to place it. Long-press Space
  (or slide while holding Space) enters trackpad mode to move the caret.
- **QuickType emphasis:** when a spelling fix is pending, the center suggestion is
  a rounded gray emphasized chip (`“typed”` | correction | alternate).

CSV rows include `suggestions_offered`, `selected_suggestion`, edit lineage, and
JSON touch samples (coordinates, radius, force, timing).

## Data storage and transfer

Study records are persisted locally with SwiftData. Gaussian training taps, hand
images, and IMU recordings remain in the app's Documents directory.

At the study summary, `DataExporter` writes CSV/PDF/ZIP artifacts to a temporary
local URL and `UIActivityViewController` presents the standard iOS share sheet.
Researchers can choose AirDrop, Files, Mail, or another installed share target.
No automatic network upload occurs and no server is needed.

The removed `BackendClient`, system keyboard extension, encrypted App Group
ledger, and Supabase uploader are not part of this architecture.

## Current scope

The in-app keyboard includes the candidate bar, classic/Gaussian hit routing,
letters, shift/caps lock, number and symbol layouts, space, return, delete repeat,
touch sliding, key popups, haptics, and detailed persisted touch samples.
Emoji, one-handed layout, trackpad cursor movement, and dictation are not
implemented in the in-app version.
