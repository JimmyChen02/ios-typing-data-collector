# Review: Smooth progress ring for HandCaptureView (branch `model`)

## VERDICT: REQUEST CHANGES

Do NOT merge. The ring smoothness and per-hand color are correctly implemented, but
the diff is NOT purely additive/visual: it silently changes capture timing and the
capture-lifecycle teardown, in direct violation of the spec's "do not change" list.
The requested checkmark also effectively never renders. Both must be addressed.

---

## Blocking issues

### B1. Capture duration changed 60s -> 30s (out of scope; alters collected data)
`HandCaptureView.swift:26`
```
-private let captureSeconds: Int  = 60    // seconds per condition (human override: 60s)
+private let captureSeconds: Int  = 30    // seconds per condition (~60 frames @ 2Hz)
```
spec.md line 118 explicitly lists `captureSeconds` as out of scope. This halves the
frames collected per condition (~120 -> ~60). This is a data/behavior change, not a
visual one, and it was NOT disclosed in changes.md (which claims "purely visual" and
"capture timing ... completely unchanged"). Either revert to 60, or get explicit human
sign-off that 30s is intended — but it cannot ride in silently under a visual-ring spec.

### B2. `.onDisappear` teardown removed from `capturingView` (out of scope; lifecycle change)
`HandCaptureView.swift:~252` (deleted block)
The per-condition `.onDisappear { capture.stop(); countdownTask?.cancel() }` on
`capturingView` was deleted, and the stop/cancel was moved into `startCondition`
(lines 315-316). spec.md lines 17-19 and 118-122 forbid touching `finishCondition`,
`startCondition`, and `countdownTask`. This rewrites the capture-engine lifecycle:
previously the AVCaptureSession was torn down when the capturing view disappeared; now
it is only stopped at the start of the next condition / on sheet dismiss. Functionally
it may be fine (finishCondition still calls capture.stop()), but it is an undisclosed
lifecycle change in explicitly-out-of-scope code and needs its own justification + test,
not a free rider on a visual ring. Note the top-level sheet `.onDisappear` at line
107-114 still guards early dismiss, so the engine likely still stops on dismiss — but
the per-condition stop now depends entirely on `finishCondition`/`startCondition`
running, which is a real behavioral narrowing that must be reviewed deliberately.

### B3. Checkmark requested feature does not render (explicit human request)
`HandCaptureView.swift:~197-201` and `countdownTask` at lines 352-364.
The tester is correct. In `countdownTask` the loop writes `secondsRemaining = remaining`
(reaching 0 on the final iteration), the loop exits, then `finishCondition(hand)` runs
in the SAME Task continuation with NO intervening `await` or yield. `finishCondition`
sets `phase = .reviewing` or calls `startCondition(next)`, replacing the capturing view.
SwiftUI is not guaranteed (in practice, will not get) a render pass between the
`secondsRemaining == 0` write and the phase change, so the `Image(systemName:
"checkmark")` branch is never painted. The user EXPLICITLY asked for "seconds, then
checkmark," so as written the requested feature is non-functional. This is what makes
the verdict REQUEST CHANGES rather than APPROVE WITH NITS.

Minimal correct fix (choose the safest that does NOT alter capture timing or drop
frames):
- PREFERRED: show the checkmark on the `.reviewing` transition / a dedicated brief
  "condition complete" state, OR add a `@State var showCheck` set true right before
  `finishCondition` with a single non-blocking yield (`await Task.yield()` /
  `try? await Task.sleep(nanoseconds: ~400_000_000)`) inserted AFTER the last frame is
  captured and AFTER `secondsRemaining = 0` but BEFORE `finishCondition`. Because all
  frames are gathered during the 30 (or 60) one-second ticks, a short post-countdown
  pause adds no frames and drops none — capture is already done when the loop exits. It
  does delay auto-advance by that fraction of a second, which is a product call; if any
  delay to auto-advance is unacceptable, then move the checkmark to the reviewing screen
  instead. Do NOT put the delay inside the per-second loop.
- Either way, confirm with the human whether a ~0.4s pause before auto-advance is
  acceptable; if not, the reviewing-screen checkmark is the zero-timing-impact option.

---

## Out-of-scope / undisclosed changes bundled in the working tree (not this file)

These appear in `git diff HEAD` and are NOT part of a visual-ring increment. They may be
leftovers from prior work, but they are currently uncommitted in the same tree and would
be swept into any commit. Flagging so they are not merged blindly:

- `TypingResearch.xcodeproj/project.pbxproj`: HC* build-file/file-ref entries are only
  REORDERED (all 5 HandSample/HandImageStore/MotionRecorder/HandCaptureView/
  HandBurstCapture entries intact, no new files, no corruption — verified). BUT it also
  changes `DEVELOPMENT_TEAM 55A7CXN98C -> P2LUTF8N6F` and
  `PRODUCT_BUNDLE_IDENTIFIER com.trantran.typingresearch -> com.jimmychen.typingresearch`
  in both build configs. These are signing-identity changes; confirm intentional and
  keep them out of a shared/upstream merge if not.
- `CustomKeyboardView.swift` and `GaussianKeyboardView.swift`: keyboard key-height is
  changed from fixed 42pt to a derived/clamped height. Unrelated to this increment and
  unreviewed here. Should be a separate change with its own spec/tests.

---

## What is correct (no action needed)

- captureProgress (`HandCaptureView.swift:432-438`): derived solely from
  `secondsRemaining`, clamped 0...1, guard against total==0. No separate timer /
  TimelineView / Date(). Resets to 0 at condition start (startCondition sets
  secondsRemaining = captureSeconds at line 318) and reaches 1.0 when secondsRemaining
  hits 0. Animation keyed on `secondsRemaining` via the unchanged
  `.animation(.linear(duration: 1), value: secondsRemaining)` (line 192) gives a
  genuinely smooth, drift-free per-tick sweep. Correct approach.
- ringColor(for:) (`HandCaptureView.swift:443-450`): exhaustive over HoldingHand
  (left/right/both/unknown), used consistently for ring stroke (189) and checkmark (201).
  left=blue / right=green / both=orange / unknown=orange. Tasteful and app-consistent.
- `.id(hand)` (line 96): correctly forces view recreation per condition so the ring
  starts clean. Good.

## Nits

- N1. checkmark `Image` uses `.font(.system(size: 48, weight: .bold))` without the
  `design: .monospaced` used by the countdown text — minor inconsistency, irrelevant if
  the checkmark is reworked per B3.
