# 2026-07-15 — Adaptive (gaussian) keyboard latency investigation + fix

**Branch:** `tran/fix-latency-2` (created from `model` with fixes in progress)

## Symptom
Adaptive mode only: extreme typing lag, late-logged inputs, missed keys during
fast two-thumb typing, brief screen freezes. Classic mode fine. Prior
investigations looked at "calculation between types" (the Gaussian scoring) and
found nothing — correctly, as it turns out.

## What was ruled out
- `GaussianKeyModel.winner()` — anchor check + argmax over ~26 keys, ~6
  multiplies each. Negligible.
- `SessionManager.captureEvent` / `handleKeyTap` — identical code path for both
  modes; cannot explain a mode-specific difference.
- Model loading — `GaussianModelStore.loadModel` runs once in `TrialView.onAppear`.

## Actual causes (all in `GaussianKeyboardView.swift`)
1. **Dropped overlapping touches.** The single full-keyboard `TouchOverlayView`
   had `isMultipleTouchEnabled = false` → UIKit silently discards a second
   thumb's touch-down while the first is still down. A `didDispatch` flag also
   ate any `touchesBegan` before the previous `touchesEnded`. This is the
   "misses inputs when typing fast" bug. Classic mode's per-key `DragGesture`s
   never had this problem.
2. **Whole-keyboard re-render per tap.** `pressedKey`/`pressedRect` `@State` on
   the top-level view invalidated all ~30 shadowed keycaps on every press and
   release — the exact "in-flight SwiftUI re-render blocks touch delivery"
   problem the overlay's own header comment said it was built to avoid.
3. **Synchronous haptic before dispatch** in `touchesBegan`, with `prepare()`
   only at init.

## Fixes
1. Multi-touch on; dispatch every touch in `touchesBegan`; clear the pressed
   visual only when `event.allTouches` shows no active finger.
2. Static keycaps extracted to `KeyboardVisualLayer: View, Equatable` +
   `.equatable()`; pressed visual is now a small highlight overlay + callout.
3. Haptic fires after dispatch and re-`prepare()`s.

## Outcome
Build succeeded (iPhone 17 simulator — this machine has no iPhone 16 sim; the
CLAUDE.md build command is stale on that point). Not yet verified on device.
Fingerprint to confirm on device: fast *alternating-thumb* sequences previously
lost keys; single-finger fast tapping mostly didn't.
