# 2026-07-24 — Stage 3: finish the iOS keyboard replica (minus dictation / QuickPath)

**Context:** `AdaptiveKeyboard/`, `TypingResearchShared/AdaptiveKeyboardCore.swift`,
`TypingResearch/Views/AdaptiveKeyboardHomeView.swift`. Goal: close the remaining
fidelity gaps from stage 2 while leaving the local language model untouched.

**Attempted:**
- New `AdaptiveKeyboard/EmojiKeyboardView.swift` (UICollectionView grid, category
  bar, recents in the App Group). Registered by hand in `project.pbxproj`:
  `PBXBuildFile AK…007`, `PBXFileReference AK…108`, the `AdaptiveKeyboard` group,
  and the extension's `Sources` phase (`AK…203`).
- Rewrote `KeyboardViewController.swift`: long-press alternates with
  slide-to-select, one-handed mode + expand handle, landscape metrics, space-bar
  trackpad, word-deletion escalation, SF Symbol key glyphs, blue Return.
- Shared core: `KeyboardLayoutMode.emoji`, `OneHandedMode`, `KeyAlternates`,
  `SmartPunctuation`, and six settings-parity toggles on
  `SharedKeyboardPreferences` (all default on).

**Errors:**
- `traitCollectionDidChange` deprecation warning on iOS 17.
- One typo (`setOneHaneded`) caught at compile time.

**Fix / outcome:** Replaced the trait override with
`registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self])`.
Build clean, 12/12 tests pass.

Working invocation (simulator id avoids name-resolution flakiness):

```sh
xcodebuild test -scheme TypingResearch \
  -destination 'platform=iOS Simulator,id=8AFDD6AA-C074-485D-8886-9A221886BD4C' \
  CODE_SIGNING_ALLOWED=NO -quiet
```

**Notes for next agent:**
- Keyboard height is now dynamic (`preferredHeight`): landscape and the
  Predictive toggle both change it, so don't reintroduce a fixed 292pt constraint.
- Emoji taps log as `.touch` with `metadata["source"] == "emoji"`; the touch
  point rides in metadata because the coordinates come from the collection view,
  not a `UITouch` in the keyboard view's space.
- `logs/` did not exist when piping `xcodebuild ... | tee logs/…`; create it first
  or skip the tee.
- Still open: emoji search field, skin-tone picker, and the real language model.
