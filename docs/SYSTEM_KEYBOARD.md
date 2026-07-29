# System-wide research keyboard (stage 3)

## Goal for this stage

Complete the English iPhone keyboard replica, excluding dictation and QuickPath:

1. Stock iOS chrome (gray/white keys, SF Symbol glyphs, suggestion bar, light/dark).
2. Character-preview popups and long-press accent/alternate menus.
3. Emoji page with categories and recents.
4. Landscape metrics, one-handed mode, space-bar trackpad.
5. Settings-parity toggles honored by the extension.
6. Every touch / suggestion / autocorrect / emoji event logged to the App Group.

A red recording dot is the only research marker. The language model is still the
small local decoder from stage 2; Gaussian adaptation remains deferred.

## Reality check

A third-party `UIInputViewController` cannot be a bit-perfect clone of Apple’s
keyboard. Apple’s layout assets, hit-test model, language model, dictation,
inline predictions inside the text field, and system text replacements are
private. This stage targets high visual/behavioral fidelity for English QWERTY
in portrait.

## iOS keyboard feature inventory

### Layout and chrome
- QWERTY letter layout; 123 / #+= symbol pages
- Shift / caps lock; auto-capitalization after `.?!` and at sentence start
- Delete with long-press repeat
- Space, Return (context label: return/go/search/send/…)
- Globe / next keyboard
- Emoji keyboard entry point
- Light / dark appearance matching system
- Portrait and landscape layouts; iPad floating / split / undocked
- One-handed mode (left/right shrink)

### Key interaction feedback
- Key popup / magnifier bubble on press
- Key highlight / press state
- Optional click sound and haptics
- Long-press accent / alternate character menus
- Long-press number/symbol alternates on letter keys

### Text intelligence
- Auto-Correction
- Predictive / QuickType suggestion bar
- Inline gray predictive completions in the text field (system-owned)
- Spell check underlines (host text system)
- Slide to Type / QuickPath
- Double-space → period
- Auto-capitalization / Caps Lock
- Shortcut / text replacement
- Contact name suggestions
- Multilingual typing / automatic language switching
- Dictation
- Undo autocorrect via backspace shortly after correction

### Editing helpers
- Space-bar trackpad mode
- Select / copy / paste / cut (host-owned)
- Undo / redo gestures (host-owned)

### Other
- Password / secure-field fallback to system keyboard
- External hardware keyboard support
- Accessibility (VoiceOver, Switch Control, …)
- Settings toggles for Auto-Capitalization, Auto-Correction, Predictive, etc.

### Implemented through stage 3
- Stock iOS-like visuals (light/dark), SF Symbol shift/delete/globe/emoji glyphs
- Shift key turns white when engaged; blue Return for go/search/send/done/…
- Character preview popup + press highlight + slide-to-neighbor
- Long-press accent and punctuation alternates with slide-to-select
- Momentary 123 / #+= gesture: hold the layout key, slide to a symbol, and
  release to insert it while returning to the original layout
- Emoji page: 8 categories + recents, ABC/globe/delete, delete repeat
- Landscape metrics (shorter rows, tighter gaps) and one-handed left/right mode
  with an expand handle; also reachable by holding the globe key
- Space-bar trackpad on long press with accumulated fine horizontal movement,
  hold-movement tolerance, and best-effort vertical line movement
- Accelerating delete repeat, escalating from characters to word deletion
- Smart punctuation (curly quotes, `--` → em dash), double-space → period
- Suggestion bar (local decoder, up to 3 candidates), autocorrect on
  space/return + undo via backspace
- Autocorrect covers confident substitutions, adjacent transpositions, and
  one-character insertion/deletion typos; sentence punctuation also commits it
- Longer completions remain suggestions until explicitly tapped; pressing space
  commits the typed literal unless a qualifying typo autocorrection applies
- Temporary autocorrect correction chip in the suggestion bar with underlined
  replacement and tap-to-revert quoted original
- Settings parity: Auto-Capitalization, Auto-Correction, Predictive, Character
  Preview, Caps Lock, Smart Punctuation, One-Handed — set in the app, honored
  live by the extension
- Encrypted event logging (including emoji taps and layout switches) + in-app
  typed text

### Deferred / out of reach
- Dictation and QuickPath (explicitly out of scope)
- Emoji search field, skin-tone variant picker
- Apple's language model and host-app inline prediction styling in arbitrary
  apps (the inline-prediction feature has been removed from this keyboard)
- Text replacement shortcuts, contact suggestions, multilingual auto-switching
- iPad floating / split / undocked layouts
- Adaptive Gaussian personalization
- Secure-field typing (iOS forces the system keyboard)

## Targets

- `TypingResearch`: containing app with typing field, enablement, pause/export/delete
- `AdaptiveKeyboard`: `UIInputViewController` extension
- `TypingResearchShared`: event schema, encrypted ledger, local decoder, preferences

App Group: `group.edu.cornell.ab3235.typingresearch`. Full Access is required
for shared research logging.

## Enable on a device

1. Install and launch TypingResearch.
2. Settings → General → Keyboard → Keyboards → Add New Keyboard → Adaptive Keyboard.
3. Enable Allow Full Access.
4. On the Keyboard tab, focus the text field and switch to Adaptive Keyboard.
5. Hold a letter to see the popup; type `teh` + space to see autocorrect.
6. Hold `e` for accents, hold space for the trackpad, hold the globe key for
   one-handed mode, tap the smiley key for emoji.

## Logging

Recording is on by default and can be paused from the app. Events include
touch coordinates, key frames, suggestions, autocorrect accept/revert, emitted
text, context, and latency. Events are AES-GCM encrypted in the App Group.
