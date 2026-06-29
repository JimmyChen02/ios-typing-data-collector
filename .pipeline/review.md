# Final Review — Multi-frame HandyTrak burst capture (branch `model`)

## VERDICT: APPROVE WITH NITS

The build is green (BUILD SUCCEEDED, Xcode 26.1.1 / Swift 6.2.1 after the two
documented post-test fixes). The increment matches the spec, the schema/trainer
contract is intact, the guided 3-condition flow is correct, and the two
`nonisolated(unsafe)` fields are genuinely race-free (not merely
compiler-silenced). The mirroring choice is research-safe for the actual
trainer (reasoning below). No BLOCKING issues. The nits are real but
non-corrupting and can ship or be fixed in a follow-up.

---

## 1. AVFoundation lifecycle & mirroring — PASS (with one consistency caveat)

Lifecycle is sound:
- No force-unwrap on the camera device — `guard let device = AVCaptureDevice.default(...)`
  (HandBurstCapture.swift:101) returns via `onUnavailable?()` on Simulator / no
  front cam. Input creation is `try?` + `canAddInput` guarded (114-118); output
  add is `canAddOutput` guarded (126-129). No crash paths.
- `startRunning()` (146) and `stopRunning()` (93) both dispatched to the private
  serial `sessionQueue`, off the main thread, as required.
- Idempotency: `start()` early-returns on `isConfigured` (61); `stop()` nils the
  session and is nil-safe (88-95). Both safe to call repeatedly — and the view
  does call `stop()` redundantly (onDisappear + finishCondition + skip), which
  is fine.
- No retain cycles: the `requestAccess` completion and the delegate `Task` both
  use `[weak self]` (70-71, 188). `onFrame`/`onUnavailable` are plain stored
  closures cleared when the view's `@State capture` is replaced each condition.

**Mirroring (the research-critical point) — research-safe, but note the comment
is technically wrong.** The code applies `UIImage(... orientation: .upMirrored)`
(183) with the stated intent "left side of screen = left in image." The
justification in the code comment is inaccurate: `AVCaptureVideoDataOutput` from
the front camera delivers RAW, NON-mirrored sensor buffers by default (unlike
the auto-mirrored on-screen preview and unlike `AVCapturePhotoOutput`), because
the connection's `isVideoMirrored` is never enabled here. So `.upMirrored` does
not "undo" a mirror — it *introduces* a horizontal flip. (Note also that
`jpegData()` bakes UIImage orientation into pixels, so the flag does take effect
in the saved JPEG — good.)

Why this is NOT a dataset-corrupting blocker:
- The flip is applied **identically to every frame of every condition for every
  participant** — `throttleInterval`/conversion path is unconditional. The
  HandyNet CNN (the headline `handynet_windowed_acc` classifier) learns whatever
  consistent orientation it is shown; a globally-consistent horizontal flip does
  not invert the *label*, it only relabels which silhouette-x corresponds to
  which class — and the CNN is trained on those same images, so it is invariant
  to the choice.
- The centroid baseline explicitly disclaims orientation: its docstring
  (train_hand_classifier.py:624-628) says "this is a HEURISTIC and the front
  camera mirrors the image. Do NOT over-invest in which side is which... The
  baseline's job is a SEPARABILITY SANITY CHECK." A consistent flip preserves
  separability; only per-frame INCONSISTENT mirroring would corrupt anything,
  and that cannot happen here.

NIT (not blocking): the comment at 180-182 misstates the cause (raw buffers
aren't pre-mirrored). Either drop `.upMirrored` (use `.up`) or fix the comment.
Because consistency is what matters, leaving it as-is does not harm the dataset.

---

## 2. Trainability fidelity — PASS

- Per-frame HandSample, one JPEG + one row (saveFrame, HandCaptureView.swift:387-421),
  reusing HandImageStore — no new schema/storage.
- `studySessionIndex = frameIndex` (407), a per-condition counter reset to 0 in
  `startCondition` (310) and incremented per frame (420). This gives the trainer
  the tie-free, strictly-increasing primary sort key it wants
  (hand_dataset.py:198 sorts on `(study_session_index, captured_at_iso,
  image_relative_path)`). `captured_at: Date()` (408) is the monotonic
  secondary key. Correct.
- `holdingHand: hand` per condition (409), `cameraPosition: "front"` (413).
- saveImage-nil path still inserts a label-only row (389-397) — matches spec
  edge case 2; frame counter still advances.
- Manifest is the unchanged 14-column schema: DataExporter.exportHandManifestCSV
  header (DataExporter.swift:125-130) is byte-for-byte the column set the Python
  loader reads (hand_dataset.py:10-11, 252-253). Confirmed identical.
- ~120 frames @ 2 Hz over 60 s: `captureSeconds = 60`, `targetFPS = 2.0`
  (HandCaptureView.swift:26-27), both one-line tunable. The
  `throttleInterval = 1.0 / max(targetFPS, 0.1)` (HandBurstCapture.swift:142)
  enforces 2 Hz by PTS gating (164-170) regardless of the 30 fps source.

---

## 3. Guided 3-condition flow + SessionView — PASS

- intro → capturing(.left) → capturing(.right) → capturing(.both) → reviewing,
  driven by `finishCondition` (HandCaptureView.swift:360-381). Counts recorded
  per condition for the review screen.
- `collected` aggregates all frames across conditions (419); review "Save &
  Continue" calls `onComplete(collected)` (280).
- Skip / Discard / early sheet-dismiss all call `stop()` + cancel countdown and
  pass `nil` (skip 425-429; onDisappear 106-113). Non-blocking; "keep nothing on
  early dismiss" honored.
- Camera-unavailable path sets `cameraUnavailable`, cancels countdown, shows Skip
  — no crash, no UIImagePicker fallback (324-332, 214-236).
- SessionView closure loops `for sample in samples { recordHandSample(sample) }`
  (SessionView.swift) with no change to SessionManager's method. Export wiring
  (`exportHandData`, multi-URL ShareItem) is coherent.

---

## 4. Concurrency soundness of the two `nonisolated(unsafe)` fields — PASS (genuinely sound)

`throttleInterval` (HandBurstCapture.swift:51): written exactly once on the main
actor in `configureAndStart` (142) BEFORE `session.startRunning()` is dispatched
to `sessionQueue` (145-147). Frames only flow after `startRunning`, and the
delegate fires only on `sessionQueue`, which reads it (164). The write
happens-before the dispatch (same-thread program order), and the dispatched
block establishes the ordering edge to the queue — so the read on `sessionQueue`
always sees the written value. After that it is read-only. No race. This is real
soundness, not compiler-silencing.

`lastEmittedPTS` (45): reset to `.invalid` on the main actor in
`configureAndStart` (141) before `startRunning` is dispatched; thereafter
read/written ONLY inside `captureOutput` (167, 185), which runs on the single
serial `sessionQueue`. A serial queue serializes all accesses — no concurrent
access. The initial main-actor reset is likewise ordered before any frame via
the `startRunning` dispatch. Sound.

One subtlety worth noting (not a bug): because `start()` replaces nothing and
`stop()` nils the session and a NEW `HandBurstCapture()` is constructed per
condition (HandCaptureView.swift:317), there is never a second concurrent
producer on a shared instance. Each instance's `sessionQueue` is private and
serial. Clean.

---

## 5. docs/HAND_DATA_COLLECTION.md — PASS

End-to-end path is correct and runnable: export ("Hand Manifest CSV + Images")
→ place CSV beside `hand_images/` → `.venv-ml/bin/python
scripts/train_hand_classifier.py <manifest> --images-root <dir> --out models/
--mode both` → read `models/summary.json`. The command matches the actual
argparse (positional `manifest`, `--images-root`, `--out`, `--mode`, `--epochs`,
`--demo`; train_hand_classifier.py:935-975). summary.json field list matches.
Numbers are internally consistent with the implemented constants (60 s, 2 Hz,
~120 frames/condition, ~360/participant).

NIT: the doc says tap export on the "Collection Complete / Study Complete"
summary screen — verify that copy matches the actual SummaryView title string;
minor wording only.

---

## 6. Python / tests / SessionManager — CONFIRMED unchanged this increment

`scripts/` and `tests/` are entirely untracked on this branch (the whole hand
pipeline was introduced earlier and not yet committed), so there is no in-branch
modification to them in this increment — consistent with the "Python unchanged"
claim. pytest (28 passed) and `--demo` (exit 0, summary.json written) both green
per test-results.

DOC INCONSISTENCY (non-blocking, already flagged by the tester): changes.md says
SessionManager was "not touched," but it does contain `pendingHandSamples` and
`recordHandSample`. These are additive and required by this flow; they predate or
accompany the increment and break nothing. Documentation wording only — no code
defect.

---

## Required fixes for SHIP: NONE (build green, no corrupting issues)

## Recommended (non-blocking) follow-ups
1. HandBurstCapture.swift:180-183 — fix the misleading mirroring comment, and
   decide deliberately between `.up` and `.upMirrored`. Either is dataset-safe
   because the transform is globally consistent and the trainer is
   orientation-agnostic; just make the comment accurate so a future editor
   doesn't "correct" it and accidentally introduce per-frame inconsistency.
2. changes.md — correct the "SessionManager not touched" line.
3. docs — confirm the summary-screen button/title copy matches SummaryView.
