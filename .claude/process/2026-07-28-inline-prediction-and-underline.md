# 2026-07-28 — Inline prediction + temporary autocorrect underline

**Context:** stage-3 keyboard replica needed iOS-like inline prediction and
temporary autocorrect feedback while keeping the local LM.

**Attempted:**
- Added `KeyboardLivePredictionState` to shared core and persisted it in
  `SharedKeyboardPreferences`.
- Added `inlinePredictionAccepted` event and `CorrectionFeedbackPolicy.inlineCompletion`.
- Updated `KeyboardViewController` to:
  - publish live prediction state each refresh,
  - accept inline completion on space/return,
  - render temporary correction chip in the candidate bar.
- Added `PredictionAwareTextEditor` in app for gray inline suffix + temporary
  underlined correction with tap-to-revert.

**Errors:**
- `xcodebuild test` repeatedly timed out on simulator boot/data migration
  (`DVTCoreSimulatorAdditionsErrorDomain`, waiting on LaunchServices migration).

**Fix / outcome:**
- Verified compile/build success via `xcodebuild ... build`.
- Left targeted test re-run as follow-up once simulator migration finishes.

**Notes for next agent:**
- Inline gray text in arbitrary host apps is not possible from keyboard
  extensions; only the app-owned field can fully render it.
- The extension approximates this via candidate-bar styling and acceptance
  behavior so interaction still matches iOS flow.
