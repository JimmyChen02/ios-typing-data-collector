# Pooled + Leave-One-User-Out Training with IMU+Silhouette Fusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pooled and leave-one-user-out (LOUO) training/eval to the holding-hand
posture classifier, for both the existing IMU-only model and a new IMU+silhouette
fusion model, with a windowed-accuracy metric that is correctly calibrated
regardless of camera capture rate.

**Architecture:** A new `scripts/window_grid.py` computes windowed accuracy over a
grid of TIME-based windows (seconds), converting to a per-session frame count from
each session's own empirically-measured capture rate — fixing the existing metric's
silent 2 Hz/30-frame calibration. `scripts/cross_user_eval.py` adopts it to
recompute the single-user cross-user baseline. `scripts/train_hand_classifier.py`
gains `--pooled`/`--pooled-louo` flags for the IMU-only model. A new
`scripts/fusion_pooled_train.py` implements a two-branch (frozen VGG16 silhouette
projection + trainable Conv1D IMU encoder) fusion model with pooled/LOUO as its
only modes, training an IMU-only comparison model on identical filtered rows in
the same run.

**Tech Stack:** Python 3.12, TensorFlow/Keras (`.venv-ml`), NumPy, pytest/unittest.
No iOS/app changes — this plan is entirely offline (`scripts/` + `tests/`).

## Global Constraints

- Run all Python from the repo root using `.venv-ml/bin/python` (NOT `venv/` —
  that has no python binary on this machine; see project memory
  `jimmy2-machine-build-env`).
- Every new/modified script must keep working when TensorFlow/Keras is absent
  (existing fallback-chain convention: `_try_import_keras()` returns `(None, None)`
  on failure, callers degrade gracefully) — do not add a hard `import tensorflow`
  at module top level in any file that must still import cleanly without it.
- No changes to `TypingResearch/` (the iOS app) or to the shipped
  `posture_imu.mlpackage` — this plan is offline-only per the design's Non-goals.
- No changes to `train_hand_classifier.py`'s existing per-participant training
  path, `windowed_accuracy()`/`sliding_window_majority_vote()` (still frame-count
  based; callers compute the count), or any existing test in
  `tests/test_hand_pipeline.py` — all additions are additive.
- Follow the existing codebase's lazy-import convention for cross-module
  dependencies to avoid circular imports (see `train_hand_classifier.py` line 127's
  comment: `imu_sequence` is imported inside `main()`, not at module top level).
  `window_grid.py` imports `windowed_accuracy`/`sliding_window_majority_vote` from
  `train_hand_classifier` **inside its own functions**, not at module top level,
  since `train_hand_classifier.py` will also import `window_grid` (inside its new
  pooled/LOUO function) — a top-level import on both sides would deadlock.
- Design doc of record: `docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md`.
  Every task below implements a specific section of it — read that doc's
  "Evaluation protocol" and "Fusion model architecture" sections for the full
  rationale behind the numbers used here.
- Test file: all new tests go in **`tests/test_pooled_fusion.py`** (new file,
  created by Task 1) — kept separate from `tests/test_hand_pipeline.py` (which
  covers the pre-existing pipeline) because this feature is a large, cohesive
  addition; splitting avoids making the existing 1500+ line file unwieldy.
- Run tests with: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v`

---

### Task 1: `scripts/window_grid.py` — time-based windowed-accuracy grid + selection rule

**Files:**
- Create: `scripts/window_grid.py`
- Create: `tests/test_pooled_fusion.py`

**Interfaces:**
- Produces (used by Tasks 2, 3, 6):
  - `WINDOW_SECONDS_GRID: list[float]` — `[0, 0.1, 0.5, 1.0, 1.5, 3.0, 5.0, 10.0, 15.0]`
  - `session_capture_dt_ms(records: list[dict], indices: list[int]) -> float | None`
  - `frames_for_seconds(dt_ms: float | None, seconds: float) -> int`
  - `windowed_accuracy_at_seconds(records: list[dict], indices: list[int], pred_labels: list[str], true_labels: list[str], seconds: float) -> float`
  - `sweep_window_sizes(records: list[dict], indices: list[int], pred_labels: list[str], true_labels: list[str], grid: list[float] = WINDOW_SECONDS_GRID) -> dict[float, float]`
  - `select_window(results: dict[float, float], tol: float = 0.002) -> float | None`
  - All functions take `records` (the full list from `hand_dataset.load_dataset_records`,
    each dict with keys `imu_path`, `sort_key`, `captured_at_iso`) and `indices`
    (absolute indices into `records`, positionally parallel to `pred_labels`/`true_labels`).

**IMPORTANT — read before writing any code in this task:** `captured_at_iso`
is written by `ISO8601DateFormatter()` with default options
(`TypingResearch/Services/DataExporter.swift:181`), which has **second-level
precision only** — no fractional seconds, e.g. `"2026-07-08T16:52:29Z"`. A
naive median-of-consecutive-frame-deltas rate estimator was tried and
verified (empirically, at realistic session sizes) to collapse to `0.0` for
**both** the old ~2 Hz rate and the new 30 fps rate — most consecutive
frames land in the same integer second, so the 1000 ms/0 ms quantization
noise swamps the true signal. `frames_for_seconds` would then treat that
`0.0` as invalid and silently fall back to a 1-frame window, quietly
defeating the entire time-based windowing feature on exactly the real data
it exists to evaluate. `session_capture_dt_ms` below instead estimates the
session's **average** rate as `(last_timestamp − first_timestamp) /
(frame_count − 1)` — the fixed-size 1-second quantization error shrinks to
a few percent for any session spanning more than a handful of seconds
(every real capture here: 30 s guided bursts, full typing trials). Verified
to ~2–5% accuracy at realistic session sizes (60 frames/30 s at 2 Hz,
900 frames/30 s at 30 fps) — see the design doc's "Evaluation protocol"
section for the full derivation.

- [ ] **Step 1: Write the failing tests for `session_capture_dt_ms` and `frames_for_seconds`**

Create `tests/test_pooled_fusion.py`:

```python
#!/usr/bin/env python3
"""
tests/test_pooled_fusion.py
----------------------------
Tests for the pooled/LOUO + IMU+silhouette fusion training feature
(docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md):
  - scripts/window_grid.py
  - scripts/cross_user_eval.py (grid-sweep wiring)
  - scripts/train_hand_classifier.py (--pooled / --pooled-louo)
  - scripts/fusion_pooled_train.py

Run from the repo root:
    .venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v
"""

from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
import unittest
import warnings
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import window_grid as wg


# ---------------------------------------------------------------------------
# Shared fixtures (kept local to this file — see Global Constraints)
# ---------------------------------------------------------------------------

def _records_one_session(n: int, dt_ms: float, imu_path: str = "sess.csv",
                          label: str = "left") -> list[dict]:
    """n records sharing one imu_path, captured_at_iso spaced dt_ms apart,
    starting at 2026-01-01T00:00:00Z. Timestamps are truncated to WHOLE
    SECONDS (no fractional part) to match the real app's ISO8601DateFormatter
    default (see this task's IMPORTANT note above) — this fixture is
    deliberately as imprecise as production data, not more precise.
    sort_key/label filled minimally (only what window_grid.py reads)."""
    from datetime import datetime, timedelta, timezone
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    records = []
    for i in range(n):
        t = start + timedelta(milliseconds=i * dt_ms)
        iso = t.strftime("%Y-%m-%dT%H:%M:%SZ")  # second precision only
        records.append({
            "imu_path": imu_path,
            "captured_at_iso": iso,
            "sort_key": (i, iso, f"img_{i}.jpg"),
            "label": label,
        })
    return records


class TestSessionCaptureDt(unittest.TestCase):

    def test_realistic_2hz_session_estimates_close_to_true_rate(self):
        """60 frames over ~30s (a real guided-burst-scale session) at the old
        500ms/frame rate -> estimate within 5% of 500.0, despite whole-second
        timestamp quantization."""
        records = _records_one_session(60, 500.0)
        dt = wg.session_capture_dt_ms(records, list(range(60)))
        self.assertIsNotNone(dt)
        self.assertLess(abs(dt - 500.0) / 500.0, 0.05)

    def test_realistic_30fps_session_estimates_close_to_true_rate(self):
        """900 frames over ~30s (a real post-B1 guided-burst session) at
        1000/30 ms/frame -> estimate within 5% of the true rate."""
        records = _records_one_session(900, 1000.0 / 30.0)
        dt = wg.session_capture_dt_ms(records, list(range(900)))
        self.assertIsNotNone(dt)
        self.assertLess(abs(dt - 1000.0 / 30.0) / (1000.0 / 30.0), 0.05)

    def test_fewer_than_two_timestamps_returns_none(self):
        records = _records_one_session(1, 500.0)
        self.assertIsNone(wg.session_capture_dt_ms(records, [0]))
        self.assertIsNone(wg.session_capture_dt_ms(records, []))

    def test_too_short_span_returns_none(self):
        """20 frames at 30fps span under 1s -> after second-truncation the
        first and last timestamp can land in the SAME second (span=0) -- must
        return None (caller falls back to 1 frame), not divide by zero or
        return a misleading rate."""
        records = _records_one_session(20, 1000.0 / 30.0)
        dt = wg.session_capture_dt_ms(records, list(range(20)))
        self.assertIsNone(dt)

    def test_unparseable_timestamps_ignored(self):
        """Records with empty captured_at_iso don't count toward the estimate."""
        records = _records_one_session(60, 500.0)
        records.append({"imu_path": "sess.csv", "captured_at_iso": "",
                         "sort_key": (60, "", "x.jpg"), "label": "left"})
        dt = wg.session_capture_dt_ms(records, list(range(61)))
        self.assertIsNotNone(dt)
        self.assertLess(abs(dt - 500.0) / 500.0, 0.05)


class TestFramesForSeconds(unittest.TestCase):

    def test_zero_seconds_is_always_one_frame(self):
        self.assertEqual(wg.frames_for_seconds(500.0, 0), 1)
        self.assertEqual(wg.frames_for_seconds(None, 0), 1)

    def test_none_dt_is_one_frame(self):
        self.assertEqual(wg.frames_for_seconds(None, 15.0), 1)

    def test_2hz_matches_historical_30_frame_15s_metric(self):
        """500ms/frame (2Hz), 15s window -> 30 frames (the original HandyTrak
        default this design replaces — anchors the new code to the old one).
        Uses the TRUE rate directly (not an estimated one) since this test
        is about the seconds->frames arithmetic, not rate estimation."""
        self.assertEqual(wg.frames_for_seconds(500.0, 15.0), 30)

    def test_2hz_1p5s_matches_original_w3_finding(self):
        """500ms/frame (2Hz), 1.5s -> 3 frames (scripts/window_sweep.py's
        2026-07-15 finding that w=3 dominated w=30 at the old cadence)."""
        self.assertEqual(wg.frames_for_seconds(500.0, 1.5), 3)

    def test_30hz_1p5s_matches_dense_sweep_finding(self):
        """33.33ms/frame (30Hz), 1.5s -> 45 frames (dense_window_sweep.py's
        2026-07-17 finding, now PosturePredictor.voteWindowSize)."""
        self.assertEqual(wg.frames_for_seconds(1000.0 / 30.0, 1.5), 45)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'window_grid'`

- [ ] **Step 3: Create `scripts/window_grid.py` with `session_capture_dt_ms` and `frames_for_seconds`**

```python
#!/usr/bin/env python3
"""
window_grid.py
--------------
Time-based windowed-accuracy evaluation (D1 design, docs/superpowers/specs/
2026-07-20-pooled-fusion-training-design.md).

train_hand_classifier.windowed_accuracy()'s window_size is a raw frame count,
historically fixed at 30 to mean "15s" at the original ~2Hz capture cadence.
That calibration silently breaks once capture rate changes (see
.claude/process/2026-07-17-30fps-imu-capture-vote-retune.md, where the SAME
"30-frame window" meant 1s instead of 15s at the new 30fps rate). This module
converts a TIME window (seconds) to a frame count PER SESSION, using that
session's own empirically-measured capture rate -- so old-rate and new-rate
sessions are evaluated on equal footing with no further code changes needed
if the rate changes again.

session_capture_dt_ms estimates a session's AVERAGE inter-frame interval as
(time span across the session) / (frame count - 1) -- deliberately NOT a
median of consecutive-frame deltas. captured_at_iso is written by
ISO8601DateFormatter() with default options
(TypingResearch/Services/DataExporter.swift:181), which has SECOND-level
precision only. A median-of-pairwise-deltas estimator was verified to
collapse to 0.0 at realistic session sizes for BOTH the old ~2Hz rate and
the new 30fps rate (most consecutive frames land in the same integer second,
so 1000ms/0ms quantization noise swamps the true signal) -- frames_for_
seconds would then silently fall back to a 1-frame window, defeating the
whole feature. The average-based estimator's error is fixed-size (bounded by
the 1-second quantization) regardless of session length, so it shrinks to a
few percent for any session spanning more than a handful of seconds -- true
of every real capture here (30s guided bursts, full typing trials).

Windows never cross a session boundary (a session = one imu_path group, same
rule scripts/dense_window_sweep.py already established for the live vote
replay). windowed_accuracy_at_seconds() combines per-session results as a
frame-count-weighted mean.

Per the mentor guidance already applied once to the live predictor's vote
window (test multiple window sizes; prefer a smaller window when its
accuracy already matches a larger one) -- WINDOW_SECONDS_GRID and
select_window() apply that same methodology to this offline metric
independently, rather than assuming the live app's 1.5s answer transfers.

Uses train_hand_classifier.windowed_accuracy()/sliding_window_majority_vote()
UNCHANGED as the underlying per-session metric -- see the Global Constraints
in docs/superpowers/plans/2026-07-20-pooled-fusion-training.md for why the
cross-import with train_hand_classifier.py is done lazily (inside functions,
not at module top level) to avoid a circular import.
"""

from __future__ import annotations

import math
from datetime import datetime

WINDOW_SECONDS_GRID = [0, 0.1, 0.5, 1.0, 1.5, 3.0, 5.0, 10.0, 15.0]


def session_capture_dt_ms(records: "list[dict]", indices: "list[int]") -> "float | None":
    """Estimate a session's AVERAGE inter-frame interval (ms) as (time span
    across `indices`' captured_at_iso timestamps) / (count - 1). See the
    module docstring for why this is NOT a median of pairwise deltas.

    Returns None when fewer than 2 records have a parseable timestamp, or
    when the parseable timestamps span zero time (e.g. a short session where
    every frame's timestamp truncates to the same second) -- callers
    (frames_for_seconds) treat None the same as the degenerate case, falling
    back to a 1-frame window for that session's contribution.
    """
    times: "list[datetime]" = []
    for i in indices:
        iso = records[i].get("captured_at_iso", "")
        if not iso:
            continue
        try:
            times.append(datetime.fromisoformat(iso.replace("Z", "+00:00")))
        except ValueError:
            continue
    if len(times) < 2:
        return None
    times.sort()
    span_ms = (times[-1] - times[0]).total_seconds() * 1000.0
    if span_ms <= 0:
        return None
    return span_ms / (len(times) - 1)


def frames_for_seconds(dt_ms: "float | None", seconds: float) -> int:
    """Convert a time window to a frame count for one session's
    windowed_accuracy() call. seconds<=0 means "per-frame" -> 1 (windowed_
    accuracy at window_size=1 collapses to raw frame accuracy by
    construction -- see sliding_window_majority_vote with window_size=1).
    dt_ms=None (session_capture_dt_ms couldn't estimate a rate) -> 1, same
    as the degenerate case. Always floors at 1.
    """
    if seconds <= 0 or dt_ms is None or dt_ms <= 0:
        return 1
    return max(1, round(seconds * 1000.0 / dt_ms))
```

- [ ] **Step 4: Run tests to verify Step 1's tests now pass**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v`
Expected: `TestSessionCaptureDt` and `TestFramesForSeconds` PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/window_grid.py tests/test_pooled_fusion.py
git commit -m "Add window_grid: session-rate-aware time windows for windowed accuracy"
```

- [ ] **Step 6: Write the failing tests for `windowed_accuracy_at_seconds`**

Append to `tests/test_pooled_fusion.py`. These "mechanics" tests (grouping,
boundary respect, aggregation) deliberately use a WHOLE-SECOND rate (1000ms
= 1Hz) so `session_capture_dt_ms` recovers the true rate with ZERO
estimation error — keeping these tests about the aggregation logic, not
entangled with the rate-estimation accuracy already covered by
`TestSessionCaptureDt` above:

```python
class TestWindowedAccuracyAtSeconds(unittest.TestCase):

    def test_matches_direct_call_single_session(self):
        """One session, one window size -> matches calling windowed_accuracy
        directly with the frame count frames_for_seconds() computes.
        1Hz spacing -> session_capture_dt_ms recovers exactly 1000.0 (whole
        seconds, no truncation error), so this equality is exact."""
        from train_hand_classifier import windowed_accuracy
        records = _records_one_session(20, 1000.0)  # 1Hz, exact
        pred = ["left"] * 12 + ["right"] * 8
        true = ["left"] * 20
        seconds = 3.0  # -> 3 frames at 1Hz
        got = wg.windowed_accuracy_at_seconds(records, list(range(20)), pred, true, seconds)
        want = windowed_accuracy(pred, true, window_size=3)
        self.assertAlmostEqual(got, want, places=6)

    def test_never_crosses_session_boundary(self):
        """Two sessions concatenated -> result equals the manually-computed
        frame-count-weighted mean of each session's OWN windowed_accuracy,
        proving no window spans the boundary between them."""
        from train_hand_classifier import windowed_accuracy, sliding_window_majority_vote
        recs_a = _records_one_session(10, 1000.0, imu_path="a.csv")
        recs_b = _records_one_session(10, 1000.0, imu_path="b.csv")
        records = recs_a + recs_b
        pred = ["left"] * 6 + ["right"] * 4 + ["right"] * 7 + ["left"] * 3
        true = ["left"] * 10 + ["right"] * 10
        seconds = 3.0  # -> 3 frames at 1Hz

        got = wg.windowed_accuracy_at_seconds(records, list(range(20)), pred, true, seconds)

        acc_a = windowed_accuracy(pred[:10], true[:10], window_size=3)
        acc_b = windowed_accuracy(pred[10:], true[10:], window_size=3)
        n_a = len(sliding_window_majority_vote(pred[:10], window_size=3))
        n_b = len(sliding_window_majority_vote(pred[10:], window_size=3))
        want = (acc_a * n_a + acc_b * n_b) / (n_a + n_b)
        self.assertAlmostEqual(got, want, places=6)

    def test_seconds_zero_equals_frame_accuracy(self):
        records = _records_one_session(10, 1000.0)
        pred = ["left"] * 7 + ["right"] * 3
        true = ["left"] * 10
        got = wg.windowed_accuracy_at_seconds(records, list(range(10)), pred, true, 0)
        self.assertAlmostEqual(got, 0.7, places=6)


class TestSweepAndSelect(unittest.TestCase):

    def test_sweep_returns_one_entry_per_grid_value(self):
        records = _records_one_session(20, 1000.0)
        pred = ["left"] * 20
        true = ["left"] * 20
        grid = [0, 1.5, 15.0]
        results = wg.sweep_window_sizes(records, list(range(20)), pred, true, grid=grid)
        self.assertEqual(set(results.keys()), set(grid))
        for acc in results.values():
            self.assertAlmostEqual(acc, 1.0, places=6)

    def test_select_window_prefers_smaller_within_tolerance(self):
        """Best accuracy at 15.0s (0.952); 0.5s and 1.5s are within tol=0.002
        of it -> smallest of those (0.5) is selected, not the raw best."""
        results = {0: 0.80, 0.5: 0.951, 1.5: 0.9515, 15.0: 0.952}
        selected = wg.select_window(results, tol=0.002)
        self.assertEqual(selected, 0.5)

    def test_select_window_single_best_no_ties(self):
        results = {0: 0.5, 1.5: 0.6, 15.0: 0.99}
        self.assertEqual(wg.select_window(results, tol=0.002), 15.0)

    def test_select_window_all_nan_returns_none(self):
        results = {0: float("nan"), 1.5: float("nan")}
        self.assertIsNone(wg.select_window(results))
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v`
Expected: FAIL with `AttributeError: module 'window_grid' has no attribute 'windowed_accuracy_at_seconds'`

- [ ] **Step 8: Add `windowed_accuracy_at_seconds`, `sweep_window_sizes`, `select_window` to `scripts/window_grid.py`**

Append to `scripts/window_grid.py`:

```python
def windowed_accuracy_at_seconds(
    records: "list[dict]",
    indices: "list[int]",
    pred_labels: "list[str]",
    true_labels: "list[str]",
    seconds: float,
) -> float:
    """windowed_accuracy() at a TIME window, grouped by session (imu_path) so
    no window straddles a session boundary, combined as a frame-count-
    weighted mean across sessions. `indices` are absolute indices into
    `records`, positionally parallel to `pred_labels`/`true_labels`.
    """
    from train_hand_classifier import windowed_accuracy, sliding_window_majority_vote

    groups: "dict[str | None, list[int]]" = {}
    for pos, i in enumerate(indices):
        groups.setdefault(records[i].get("imu_path"), []).append(pos)

    total_correct = 0.0
    total_windows = 0
    for _session_key, positions in groups.items():
        positions.sort(key=lambda pos: records[indices[pos]]["sort_key"])
        session_record_idx = [indices[p] for p in positions]
        dt_ms = session_capture_dt_ms(records, session_record_idx)
        frames = frames_for_seconds(dt_ms, seconds)

        pred_seq = [pred_labels[p] for p in positions]
        true_seq = [true_labels[p] for p in positions]
        acc = windowed_accuracy(pred_seq, true_seq, window_size=frames)
        if math.isnan(acc):
            continue
        n_windows = len(sliding_window_majority_vote(pred_seq, window_size=frames))
        total_correct += acc * n_windows
        total_windows += n_windows

    if total_windows == 0:
        return float("nan")
    return total_correct / total_windows


def sweep_window_sizes(
    records: "list[dict]",
    indices: "list[int]",
    pred_labels: "list[str]",
    true_labels: "list[str]",
    grid: "list[float]" = WINDOW_SECONDS_GRID,
) -> "dict[float, float]":
    """windowed_accuracy_at_seconds() for every value in `grid`."""
    return {
        s: windowed_accuracy_at_seconds(records, indices, pred_labels, true_labels, s)
        for s in grid
    }


def select_window(results: "dict[float, float]", tol: float = 0.002) -> "float | None":
    """Smallest window whose accuracy is within `tol` of the best accuracy in
    `results` (mentor guidance: test multiple window sizes; prefer a smaller
    window when it already matches a larger one's accuracy). None if every
    value is NaN (no session produced any windows at any grid size).
    """
    finite = {s: a for s, a in results.items() if not math.isnan(a)}
    if not finite:
        return None
    best = max(finite.values())
    eligible = [s for s, a in finite.items() if a >= best - tol]
    return min(eligible)
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v`
Expected: all `TestWindowedAccuracyAtSeconds` and `TestSweepAndSelect` tests PASS
(7 new tests; 17 total in the file so far)

- [ ] **Step 10: Commit**

```bash
git add scripts/window_grid.py tests/test_pooled_fusion.py
git commit -m "Add window_grid grid sweep + smallest-within-tolerance selection rule"
```

---

### Task 2: Wire the grid sweep into `scripts/cross_user_eval.py`

**Files:**
- Modify: `scripts/cross_user_eval.py`

**Interfaces:**
- Consumes: `window_grid.sweep_window_sizes`, `window_grid.select_window` (Task 1)
- Produces: `evaluate()`'s new return shape `(frame_acc, windowed_acc, selected_window_s, grid, per_class, confusion)`,
  used only within this script's own `main()` — no other task depends on it.

This task has no new unit tests (it is a thin rewiring of an existing read-only
eval script over real committed models) — verified by running it end-to-end
against real data in Step 3 and checking the printed output makes sense.

- [ ] **Step 1: Replace the fixed `VOTE_WINDOW` constant and `evaluate()` with the grid sweep**

In `scripts/cross_user_eval.py`, remove line 49 (`VOTE_WINDOW = 30     # majority-vote eval window (frames) — HandyTrak metric`)
and replace the `evaluate()` function (lines 56-62) with:

```python
def evaluate(records, indices, model, classes, feats, true_labels):
    probs = model.predict(feats, verbose=0)
    pred = [classes[j] for j in np.asarray(probs).argmax(axis=1)]
    frame_acc = float(np.mean(np.array(pred) == np.array(true_labels)))
    per_class, conf = _per_class_and_confusion(true_labels, pred, classes)
    grid = window_grid.sweep_window_sizes(records, indices, pred, true_labels)
    selected = window_grid.select_window(grid)
    win_acc = grid[selected] if selected is not None else float("nan")
    return frame_acc, win_acc, selected, grid, per_class, conf
```

Add the import (alongside the existing `from train_hand_classifier import (...)` block, after line 41):

```python
import window_grid  # noqa: E402
```

- [ ] **Step 2: Update the call site and printed output in `main()`**

Replace lines 106-114 (the per-combo evaluate call + prints):

```python
            true = [records[i]["label"] for i in idxs]
            fa, wa, sel, grid, pc, conf = evaluate(records, idxs, model, classes, X[idxs], true)
            rows.append((model_key, target_key, tag, len(idxs), fa, wa, sel))
            print(f"\n=== model[{slug(model_key)}] -> data[{slug(target_key)}]"
                  f"  ({tag}, n={len(idxs)}) ===")
            print(f"  frame-acc={fa:.3f}   windowed-acc={wa:.3f}"
                  f"  (selected window={sel}s)")
            print("  window grid: " + ", ".join(
                f"{s}s={a:.3f}" if a == a else f"{s}s=nan"
                for s, a in sorted(grid.items())))
            print("  per-class: " + ", ".join(f"{c}={v:.3f}" for c, v in pc.items()))
            conf_str = ", ".join(f"{t}->{p}:{n}" for (t, p), n in sorted(conf.items()))
            print(f"  confusion (true->pred): {conf_str}")
```

Replace the final summary table (lines 116-121):

```python
    print("\n" + "=" * 88)
    print(f"{'model':<14}{'evaluated on':<14}{'condition':<26}{'n':>6}"
          f"{'frame':>9}{'windowed':>10}{'sel(s)':>8}")
    print("-" * 88)
    for mk, tk, tag, n, fa, wa, sel in rows:
        print(f"{slug(mk):<14}{slug(tk):<14}{tag:<26}{n:>6}{fa:>9.3f}"
              f"{wa:>10.3f}{sel!s:>8}")
    print("=" * 88)
```

- [ ] **Step 3: Run against real data and sanity-check the output**

Run: `.venv-ml/bin/python scripts/cross_user_eval.py 2>&1 | tail -20`

Expected: script completes without error; the final summary table has a new
`sel(s)` column; the `anonymous_ -> jimmy_` and `jimmy_ -> anonymous_` MOCK USER
rows' `sel(s)` value and windowed accuracy should be close to the historical
15.0s/30-frame numbers (0.904 and 0.914) since `frames_for_seconds` reduces to
30 frames at 15.0s for 2Hz data (verified in Task 1's
`test_2hz_matches_historical_30_frame_15s_metric`) — but the SELECTED window
may differ from 15.0s if a smaller window in the grid already comes within
0.002 of the best accuracy (this is expected and correct — it is exactly the
mentor's "prefer the smaller window" rule doing its job on real data for the
first time). Read the full per-combo `window grid:` line to see the complete
sweep, not just the selected value.

- [ ] **Step 4: Commit**

```bash
git add scripts/cross_user_eval.py
git commit -m "cross_user_eval: sweep time-based windows instead of a fixed 30-frame/2Hz window"
```

---

### Task 3: `--pooled` / `--pooled-louo` flags in `scripts/train_hand_classifier.py`

**Files:**
- Modify: `scripts/train_hand_classifier.py`
- Modify: `tests/test_pooled_fusion.py`

**Interfaces:**
- Consumes: `window_grid.sweep_window_sizes`, `window_grid.select_window` (Task 1);
  `split_train_eval_indices`, `_predict_labels`, `_save_model`, `imu_sequence.train_imu_sequence_model` (all pre-existing).
- Produces: new CLI flags `--pooled`, `--pooled-louo` (both `action="store_true"`,
  require `--imu-seq`); on `--pooled`, writes `<out>/pooled_/{hand_model.keras,labels.json}`;
  on `--pooled-louo`, writes `<out>/louo_<safe_participant_key>/{hand_model.keras,labels.json}`
  per participant.

- [ ] **Step 1: Write the failing CLI tests**

Append to `tests/test_pooled_fusion.py`:

```python
# ---------------------------------------------------------------------------
# train_hand_classifier.py --pooled / --pooled-louo
# ---------------------------------------------------------------------------

class TestPooledLouoFlags(unittest.TestCase):

    def _run(self, extra_args, out_dir=None, timeout=300):
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        args = [sys.executable, str(script), "--demo", "--epochs", "1"] + extra_args
        if out_dir is not None:
            args += ["--out", str(out_dir)]
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

    def test_pooled_without_imu_seq_errors(self):
        result = self._run(["--pooled"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--imu-seq", result.stdout + result.stderr)

    def test_pooled_louo_without_imu_seq_errors(self):
        result = self._run(["--pooled-louo"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--imu-seq", result.stdout + result.stderr)

    def test_pooled_demo_end_to_end(self):
        with tempfile.TemporaryDirectory(prefix="thc_pooled_") as tmp:
            result = self._run(
                ["--imu-seq", "--imu-causal", "--pooled"], out_dir=None,
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            self.assertIn("Pooled model saved to:", result.stdout)

            model_out_line = next(
                l for l in result.stdout.splitlines() if l.startswith("Model out:")
            )
            model_out = Path(model_out_line.split("Model out:", 1)[1].strip())
            pooled_dir = model_out / "pooled_"
            self.assertTrue((pooled_dir / "hand_model.keras").exists()
                             or (pooled_dir / "hand_model.pkl").exists())
            self.assertTrue((pooled_dir / "labels.json").exists())
            with (pooled_dir / "labels.json").open() as fh:
                labels = json.load(fh)
            self.assertEqual(labels, ["both", "left", "right"])

    def test_pooled_louo_demo_end_to_end(self):
        result = self._run(["--imu-seq", "--imu-causal", "--pooled-louo"])
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        # Demo has 2 participants: alice|alpha and bob|beta
        self.assertIn("held_out='alice|alpha'", result.stdout)
        self.assertIn("held_out='bob|beta'", result.stdout)

        model_out_line = next(
            l for l in result.stdout.splitlines() if l.startswith("Model out:")
        )
        model_out = Path(model_out_line.split("Model out:", 1)[1].strip())
        for safe_key in ("alice_alpha", "bob_beta"):
            louo_dir = model_out / f"louo_{safe_key}"
            self.assertTrue((louo_dir / "hand_model.keras").exists()
                             or (louo_dir / "hand_model.pkl").exists())
            self.assertTrue((louo_dir / "labels.json").exists())

    def test_pooled_and_louo_together(self):
        result = self._run(["--imu-seq", "--imu-causal", "--pooled", "--pooled-louo"])
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("Pooled model saved to:", result.stdout)
        self.assertIn("held_out='alice|alpha'", result.stdout)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestPooledLouoFlags -v`
Expected: FAIL — `--pooled`/`--pooled-louo` are unrecognized arguments (argparse error, exit code 2)

- [ ] **Step 3: Add the two CLI flags**

In `scripts/train_hand_classifier.py`, in `_parse_args()` (after the `--imu-causal`
argument block, before `return parser.parse_args()` at line ~1414), add:

```python
    parser.add_argument(
        "--pooled",
        action="store_true",
        help="Also train one IMU-sequence model on ALL participants' pooled "
             "train-splits (saved to <out>/pooled_/). Requires --imu-seq.",
    )
    parser.add_argument(
        "--pooled-louo",
        action="store_true",
        help="Also run leave-one-user-out (LOUO): for each participant, train "
             "an IMU-sequence model on every OTHER participant's train-split "
             "and evaluate on that participant's FULL data (100%% unseen), "
             "saved to <out>/louo_<participant>/. Requires --imu-seq.",
    )
```

- [ ] **Step 4: Add the `--imu-seq` validation guard**

In `main()`, immediately after the existing `--imu-seq`/`--use-imu` warning block
(after line 877, before the `# IMU fusion banner.` comment at line 879), add:

```python
    if (args.pooled or args.pooled_louo) and not args.imu_seq:
        print("Error: --pooled/--pooled-louo require --imu-seq (pooled "
              "training is only implemented for the IMU-sequence model).")
        sys.exit(1)
```

- [ ] **Step 5: Run tests to verify the error-path tests now pass**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestPooledLouoFlags::test_pooled_without_imu_seq_errors tests/test_pooled_fusion.py::TestPooledLouoFlags::test_pooled_louo_without_imu_seq_errors -v`
Expected: PASS (the demo end-to-end tests still fail — `_run_pooled_and_louo` doesn't exist yet)

- [ ] **Step 6: Add `_run_pooled_and_louo` and wire it into `main()`**

In `scripts/train_hand_classifier.py`, add this function after `_save_model`
(after line 848, before `def main() -> None:` at line 851):

```python
def _run_pooled_and_louo(
    records: "list[dict]",
    participant_to_indices: "dict[str, list[int]]",
    features_arr: "np.ndarray",
    train_frac: float,
    epochs: int,
    out_dir: Path,
    do_pooled: bool,
    do_louo: bool,
) -> None:
    """Pooled + leave-one-user-out (LOUO) training for the IMU-sequence model.
    See docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md
    "Evaluation protocol". Reuses split_train_eval_indices per participant
    (same 80/20 time-ordered convention as the per-participant loop above)
    to get each participant's own train split, then unions those splits
    across participants for pooled training and leave-one-user-out training.
    LOUO evaluates on the held-out participant's FULL data (100% unseen),
    matching cross_user_eval.py's "MOCK USER" evaluation.
    """
    import window_grid
    import imu_sequence

    participant_splits: "dict[str, tuple[list[int], list[int]]]" = {}
    for p_key, p_indices in participant_to_indices.items():
        known = [i for i in p_indices if records[i]["label"] != "unknown"]
        if not known:
            continue
        labels_ = [records[i]["label"] for i in known]
        keys_ = [records[i]["sort_key"] for i in known]
        local_train, _local_eval = split_train_eval_indices(keys_, labels_, train_frac=train_frac)
        train_labels_here = [labels_[li] for li in local_train]
        if len(set(train_labels_here)) < 2:
            print(f"  pooled/LOUO: skipping participant {p_key!r} "
                  "(< 2 distinct labels in its train split)")
            continue
        abs_train = [known[li] for li in local_train]
        participant_splits[p_key] = (abs_train, known)

    if len(participant_splits) < 2:
        print("  pooled/LOUO: fewer than 2 usable participants — skipping "
              "(pooling/LOUO requires at least 2).")
        return

    def _train_and_eval(train_idx: "list[int]", eval_idx: "list[int]", tag: str) -> dict:
        train_labels = [records[i]["label"] for i in train_idx]
        model = imu_sequence.train_imu_sequence_model(
            features_arr[train_idx], train_labels, epochs=epochs
        )
        eval_labels = [records[i]["label"] for i in eval_idx]
        eval_preds = _predict_labels(model, features_arr[eval_idx])
        frame_acc = float(np.mean(np.array(eval_preds) == np.array(eval_labels)))
        grid = window_grid.sweep_window_sizes(records, eval_idx, eval_preds, eval_labels)
        selected = window_grid.select_window(grid)
        win_acc = grid[selected] if selected is not None else float("nan")
        print(f"  [{tag}] n_train={len(train_idx)} n_eval={len(eval_idx)} "
              f"frame-acc={frame_acc:.3f} windowed-acc={_fmt(win_acc)} "
              f"(selected window={selected}s)")
        print("    grid: " + ", ".join(f"{s}s={_fmt(a)}" for s, a in sorted(grid.items())))
        return {"model": model}

    if do_pooled:
        print("\n=== Pooled (IMU-only) ===")
        pooled_train_idx = [i for (t, _e) in participant_splits.values() for i in t]
        pooled_eval_idx = [i for (_t, e) in participant_splits.values() for i in e]
        result = _train_and_eval(pooled_train_idx, pooled_eval_idx,
                                  "pooled (own held-out per participant)")
        p_out_dir = out_dir / "pooled_"
        p_out_dir.mkdir(parents=True, exist_ok=True)
        unique_labels_p = sorted(set(records[i]["label"] for i in pooled_train_idx))
        with (p_out_dir / "labels.json").open("w", encoding="utf-8") as fh:
            json.dump(unique_labels_p, fh, indent=2)
        _save_model(result["model"], p_out_dir)
        print(f"  Pooled model saved to: {p_out_dir}")

    if do_louo:
        print("\n=== Leave-one-user-out (IMU-only) ===")
        for held_out_key in sorted(participant_splits):
            train_idx = [
                i for p_key, (t, _e) in participant_splits.items()
                if p_key != held_out_key for i in t
            ]
            eval_idx = participant_splits[held_out_key][1]  # FULL data, 100% unseen
            result = _train_and_eval(train_idx, eval_idx, f"LOUO held_out={held_out_key!r}")
            safe_key = re.sub(r"[^a-z0-9]+", "_", held_out_key) or "participant"
            p_out_dir = out_dir / f"louo_{safe_key}"
            p_out_dir.mkdir(parents=True, exist_ok=True)
            unique_labels_p = sorted(set(records[i]["label"] for i in train_idx))
            with (p_out_dir / "labels.json").open("w", encoding="utf-8") as fh:
                json.dump(unique_labels_p, fh, indent=2)
            _save_model(result["model"], p_out_dir)
            print(f"  LOUO model (held out {held_out_key!r}) saved to: {p_out_dir}")
```

Then in `main()`, immediately after the `if md_out:` block (after line 1193,
before `print("\nFuture work:")` at line 1195), add:

```python
    if args.imu_seq and (args.pooled or args.pooled_louo):
        _run_pooled_and_louo(
            records, participant_to_indices, features_arr,
            train_frac, epochs, out_dir, args.pooled, args.pooled_louo,
        )
```

- [ ] **Step 7: Run the full test class to verify it passes**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestPooledLouoFlags -v`
Expected: all 6 tests PASS

- [ ] **Step 8: Run the pre-existing test suite to confirm no regression**

Run: `.venv-ml/bin/python -m pytest tests/test_hand_pipeline.py -v 2>&1 | tail -20`
Expected: all pre-existing tests still PASS (this task only added new code paths
gated behind new flags — no existing behavior changed)

- [ ] **Step 9: Commit**

```bash
git add scripts/train_hand_classifier.py tests/test_pooled_fusion.py
git commit -m "train_hand_classifier: add --pooled/--pooled-louo for the IMU-sequence model"
```

---

### Task 4: Feature cache + row eligibility in `scripts/fusion_pooled_train.py`

**Files:**
- Create: `scripts/fusion_pooled_train.py`
- Modify: `tests/test_pooled_fusion.py`

**Interfaces:**
- Produces (used by Task 6):
  - `CACHE_DIR: Path` — `Model-Training-Test/cache/img_features/`
  - `image_feature_cache_path(image_path: str) -> Path`
  - `cached_image_feature(image_path: str, refresh: bool = False) -> np.ndarray`
  - `eligible_records(records: list[dict], refresh_cache: bool = False) -> tuple[list[dict], dict[str, int]]`
    — `dropped` is `{participant_key: n_dropped}`.
- Consumes: `train_hand_classifier.preprocess/segment/extract_features` (existing),
  `imu_sequence.load_imu_series` (existing).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_pooled_fusion.py`:

```python
# ---------------------------------------------------------------------------
# fusion_pooled_train.py: cache + row eligibility
# ---------------------------------------------------------------------------

def _make_solid_image(path: Path, color=(200, 100, 100), size=(64, 64)) -> None:
    from PIL import Image
    img = Image.new("RGB", size, color=color)
    img.save(str(path), format="JPEG", quality=80)


_IMU_HEADER = [
    "t_ms", "attitude_roll", "attitude_pitch", "attitude_yaw",
    "grav_x", "grav_y", "grav_z", "acc_x", "acc_y", "acc_z",
    "rot_x", "rot_y", "rot_z",
]


def _write_imu_csv(path: Path, rows: list) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(_IMU_HEADER)
        for row in rows:
            writer.writerow(row)


class TestFeatureCache(unittest.TestCase):

    def setUp(self):
        import fusion_pooled_train as fpt
        self.fpt = fpt
        self._tmp = tempfile.TemporaryDirectory(prefix="fusion_cache_")
        self._orig_cache_dir = fpt.CACHE_DIR
        fpt.CACHE_DIR = Path(self._tmp.name) / "cache"

    def tearDown(self):
        self.fpt.CACHE_DIR = self._orig_cache_dir
        self._tmp.cleanup()

    def test_cache_miss_then_hit_same_values(self):
        with tempfile.TemporaryDirectory(prefix="fusion_img_") as tmp:
            img_path = Path(tmp) / "sample.jpg"
            _make_solid_image(img_path)

            self.assertFalse(self.fpt.image_feature_cache_path(str(img_path)).exists())
            feat1 = self.fpt.cached_image_feature(str(img_path))
            self.assertTrue(self.fpt.image_feature_cache_path(str(img_path)).exists())
            feat2 = self.fpt.cached_image_feature(str(img_path))

        self.assertTrue(np.array_equal(feat1, feat2))

    def test_refresh_recomputes(self):
        with tempfile.TemporaryDirectory(prefix="fusion_img_") as tmp:
            img_path = Path(tmp) / "sample.jpg"
            _make_solid_image(img_path)
            self.fpt.cached_image_feature(str(img_path))
            cache_path = self.fpt.image_feature_cache_path(str(img_path))
            mtime_before = cache_path.stat().st_mtime_ns
            self.fpt.cached_image_feature(str(img_path), refresh=True)
            mtime_after = cache_path.stat().st_mtime_ns
        self.assertGreaterEqual(mtime_after, mtime_before)


class TestEligibleRecords(unittest.TestCase):

    def setUp(self):
        import fusion_pooled_train as fpt
        self.fpt = fpt
        self._tmp = tempfile.TemporaryDirectory(prefix="fusion_cache_")
        self._orig_cache_dir = fpt.CACHE_DIR
        fpt.CACHE_DIR = Path(self._tmp.name) / "cache"

    def tearDown(self):
        self.fpt.CACHE_DIR = self._orig_cache_dir
        self._tmp.cleanup()

    def test_drops_rows_with_unreadable_imu(self):
        with tempfile.TemporaryDirectory(prefix="fusion_elig_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            imu_dir = tmp_path / "imu"
            imu_dir.mkdir()

            _make_solid_image(img_dir / "good.jpg")
            good_imu = imu_dir / "good.csv"
            _write_imu_csv(good_imu, [[0.0] + [1.0] * 12, [20.0] + [1.0] * 12])

            _make_solid_image(img_dir / "no_imu.jpg")
            # No IMU CSV written for this row -> imu_path resolves to None
            # (hand_dataset treats a missing file as "no IMU", not skipped).

            records = [
                {
                    "image_path": str(img_dir / "good.jpg"),
                    "label": "left",
                    "participant_key": "p1",
                    "sort_key": (0, "2026-01-01T00:00:00Z", "hand_images/good.jpg"),
                    "imu_path": str(good_imu),
                    "captured_at_iso": "2026-01-01T00:00:00Z",
                },
                {
                    "image_path": str(img_dir / "no_imu.jpg"),
                    "label": "right",
                    "participant_key": "p1",
                    "sort_key": (1, "2026-01-01T00:00:01Z", "hand_images/no_imu.jpg"),
                    "imu_path": None,
                    "captured_at_iso": "2026-01-01T00:00:01Z",
                },
            ]

            kept, dropped = self.fpt.eligible_records(records)

        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["label"], "left")
        self.assertEqual(dropped, {"p1": 1})

    def test_unknown_label_rows_excluded_not_counted_as_dropped(self):
        with tempfile.TemporaryDirectory(prefix="fusion_elig_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            _make_solid_image(img_dir / "u.jpg")
            records = [{
                "image_path": str(img_dir / "u.jpg"),
                "label": "unknown",
                "participant_key": "p1",
                "sort_key": (0, "2026-01-01T00:00:00Z", "hand_images/u.jpg"),
                "imu_path": None,
                "captured_at_iso": "2026-01-01T00:00:00Z",
            }]
            kept, dropped = self.fpt.eligible_records(records)
        self.assertEqual(kept, [])
        self.assertEqual(dropped, {})

    def test_all_eligible_rows_kept(self):
        with tempfile.TemporaryDirectory(prefix="fusion_elig_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            imu_dir = tmp_path / "imu"
            imu_dir.mkdir()
            _make_solid_image(img_dir / "a.jpg")
            imu_csv = imu_dir / "a.csv"
            _write_imu_csv(imu_csv, [[0.0] + [1.0] * 12])
            records = [{
                "image_path": str(img_dir / "a.jpg"),
                "label": "both",
                "participant_key": "p1",
                "sort_key": (0, "2026-01-01T00:00:00Z", "hand_images/a.jpg"),
                "imu_path": str(imu_csv),
                "captured_at_iso": "2026-01-01T00:00:00Z",
            }]
            kept, dropped = self.fpt.eligible_records(records)
        self.assertEqual(len(kept), 1)
        self.assertEqual(dropped, {})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestFeatureCache tests/test_pooled_fusion.py::TestEligibleRecords -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'fusion_pooled_train'`

- [ ] **Step 3: Create `scripts/fusion_pooled_train.py` with the cache and eligibility functions**

```python
#!/usr/bin/env python3
"""
fusion_pooled_train.py
-----------------------
IMU + front-camera-silhouette FUSION model for holding-hand classification,
with pooled and leave-one-user-out (LOUO) training as its only modes (D1
design, docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md).

No per-participant mode -- fusion is introduced fresh alongside pooling, so
there is no legacy per-participant fusion model to preserve (unlike
train_hand_classifier.py's --pooled/--pooled-louo, which is additive next to
its existing per-participant IMU-only training).

Feature-level fusion: a frozen VGG16 silhouette feature vector (via
train_hand_classifier.preprocess/segment/extract_features, CACHED per image
since segmentation+VGG16 is the only slow stage) projected to 128-d,
concatenated with a trainable Conv1D IMU-window embedding, through a small
fusion head. See build_fusion_model() below.

Row eligibility: unlike train_hand_classifier.py's --use-imu fusion (which
zero-fills a missing IMU series), this script DROPS any row without a real,
readable IMU series for its session -- zero-filling either modality would
teach the fusion head to partially ignore it, corrupting the fusion-vs-
IMU-only comparison this script exists to make. Every eval in this script
(fusion AND its IMU-only comparison model) runs on the IDENTICAL filtered
row set.

Usage:
    .venv-ml/bin/python scripts/fusion_pooled_train.py \\
        Model-Training-Test/hand_manifest_combined.csv \\
        --images-root Model-Training-Test/ --out Model-Training-Test/models/ \\
        --pooled --pooled-louo --epochs 30
    .venv-ml/bin/python scripts/fusion_pooled_train.py --demo --pooled --epochs 1
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

import numpy as np

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

REPO = Path(__file__).resolve().parent.parent
CACHE_DIR = REPO / "Model-Training-Test" / "cache" / "img_features"

IMU_WINDOW = 50   # samples, ~1.0s at 50Hz -- matches the shipped model
IMU_CAUSAL = True  # trailing window -- matches what the live model can compute


# ---------------------------------------------------------------------------
# Feature cache
# ---------------------------------------------------------------------------

def image_feature_cache_path(image_path: str) -> Path:
    """Deterministic cache path for one image's VGG16 feature vector, keyed
    by the image's own filename stem -- stable across which participant or
    training mode is running, and across re-merges of the same export.
    """
    stem = Path(image_path).stem
    return CACHE_DIR / f"{stem}.npy"


def cached_image_feature(image_path: str, refresh: bool = False) -> "np.ndarray":
    """VGG16 silhouette feature vector for `image_path` (via
    train_hand_classifier.preprocess/segment/extract_features), computed
    once and cached to disk. A cache hit skips torch and keras entirely.
    Raises whatever preprocess()/segment()/extract_features() would raise on
    a genuinely unreadable image -- callers (eligible_records()) catch that
    and drop the row rather than silently zero-filling it.
    """
    path = image_feature_cache_path(image_path)
    if not refresh and path.exists():
        return np.load(path)

    from train_hand_classifier import preprocess, segment, extract_features
    img = preprocess(image_path)
    sil = segment(img)
    feat = extract_features(sil)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    np.save(path, feat)
    return feat


# ---------------------------------------------------------------------------
# Row eligibility
# ---------------------------------------------------------------------------

def eligible_records(
    records: "list[dict]", refresh_cache: bool = False
) -> "tuple[list[dict], dict[str, int]]":
    """Filter `records` (from hand_dataset.load_dataset_records) down to rows
    with BOTH a readable image and a readable IMU series -- fusion training
    drops incomplete rows rather than zero-filling either branch (see module
    docstring). Also excludes 'unknown'-label rows (never usable for
    training, not counted as "dropped" -- that count is reserved for rows
    that WOULD have been usable but for a missing modality).

    Returns (kept_records, dropped_counts) where dropped_counts is
    {participant_key: n_dropped}, printed by main() so a bad merge (e.g. a
    session recorded without IMU) is visible per participant, not silent.
    """
    import imu_sequence

    imu_ok_cache: "dict[str | None, bool]" = {}
    kept: "list[dict]" = []
    dropped: "dict[str, int]" = {}

    for rec in records:
        if rec["label"] == "unknown":
            continue
        imu_path = rec.get("imu_path")
        if imu_path not in imu_ok_cache:
            imu_ok_cache[imu_path] = (
                imu_path is not None and imu_sequence.load_imu_series(imu_path) is not None
            )
        if not imu_ok_cache[imu_path]:
            dropped[rec["participant_key"]] = dropped.get(rec["participant_key"], 0) + 1
            continue
        try:
            cached_image_feature(rec["image_path"], refresh=refresh_cache)
        except Exception:
            dropped[rec["participant_key"]] = dropped.get(rec["participant_key"], 0) + 1
            continue
        kept.append(rec)

    return kept, dropped


if __name__ == "__main__":
    print("fusion_pooled_train.py: CLI not yet implemented (Task 6)", file=sys.stderr)
    sys.exit(1)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestFeatureCache tests/test_pooled_fusion.py::TestEligibleRecords -v`
Expected: all 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/fusion_pooled_train.py tests/test_pooled_fusion.py
git commit -m "fusion_pooled_train: add VGG16 feature cache and row-eligibility filter"
```

---

### Task 5: Fusion model architecture

**Files:**
- Modify: `scripts/fusion_pooled_train.py`
- Modify: `tests/test_pooled_fusion.py`

**Interfaces:**
- Produces (used by Task 6):
  - `build_fusion_model(image_feature_dim: int, imu_window: int, imu_channels: int, n_classes: int) -> keras.Model`
    — two inputs `[image_features (image_feature_dim,), imu_window (imu_window, imu_channels)]`, one softmax output.
  - `train_fusion_model(img_feats: np.ndarray, imu_windows: np.ndarray, labels: list[str], epochs: int = 10) -> object`
    — mirrors `imu_sequence.train_imu_sequence_model`'s contract: attaches `._hand_classes`, savable via `train_hand_classifier._save_model`.
  - `predict_labels_fusion(model, img_feats: np.ndarray, imu_windows: np.ndarray, classes: list[str]) -> list[str]`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_pooled_fusion.py`:

```python
# ---------------------------------------------------------------------------
# fusion_pooled_train.py: model architecture
# ---------------------------------------------------------------------------

class TestFusionModel(unittest.TestCase):

    def test_build_fusion_model_shapes_and_predict(self):
        import fusion_pooled_train as fpt
        model = fpt.build_fusion_model(
            image_feature_dim=1024, imu_window=50, imu_channels=12, n_classes=3
        )
        self.assertEqual(len(model.inputs), 2)
        img_feats = np.random.randn(4, 1024).astype("float32")
        imu_windows = np.random.randn(4, 50, 12).astype("float32")
        probs = model.predict([img_feats, imu_windows], verbose=0)
        self.assertEqual(probs.shape, (4, 3))
        # Softmax rows sum to ~1
        self.assertTrue(np.allclose(probs.sum(axis=1), 1.0, atol=1e-4))

    def test_train_fusion_model_fits_and_predicts(self):
        import fusion_pooled_train as fpt
        np.random.seed(0)
        n = 12
        img_feats = np.random.randn(n, 64).astype("float32")
        imu_windows = np.random.randn(n, 50, 12).astype("float32")
        labels = ["left"] * 4 + ["right"] * 4 + ["both"] * 4

        model = fpt.train_fusion_model(img_feats, imu_windows, labels, epochs=1)

        self.assertEqual(sorted(model._hand_classes), ["both", "left", "right"])
        preds = fpt.predict_labels_fusion(model, img_feats, imu_windows, model._hand_classes)
        self.assertEqual(len(preds), n)
        for p in preds:
            self.assertIn(p, ["left", "right", "both"])

    def test_train_fusion_model_is_savable(self):
        """The fusion model must be savable via train_hand_classifier._save_model
        (reused as-is -- it just needs .save() to exist, which a keras
        functional Model has)."""
        import fusion_pooled_train as fpt
        from train_hand_classifier import _save_model
        img_feats = np.random.randn(6, 32).astype("float32")
        imu_windows = np.random.randn(6, 50, 12).astype("float32")
        labels = ["left"] * 3 + ["right"] * 3
        model = fpt.train_fusion_model(img_feats, imu_windows, labels, epochs=1)

        with tempfile.TemporaryDirectory(prefix="fusion_save_") as tmp:
            out_dir = Path(tmp)
            _save_model(model, out_dir)
            self.assertTrue(
                (out_dir / "hand_model.keras").exists()
                or (out_dir / "hand_model.pkl").exists()
            )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestFusionModel -v`
Expected: FAIL with `AttributeError: module 'fusion_pooled_train' has no attribute 'build_fusion_model'`

- [ ] **Step 3: Add the model architecture functions**

Insert into `scripts/fusion_pooled_train.py`, after the `eligible_records` function
and before the `if __name__ == "__main__":` block:

```python
# ---------------------------------------------------------------------------
# Fusion model architecture
# ---------------------------------------------------------------------------

def build_fusion_model(
    image_feature_dim: int, imu_window: int, imu_channels: int, n_classes: int
):
    """Two-branch feature-level fusion:
      image_features (image_feature_dim,) --Dense(128)--> image_128
      imu_window (imu_window, imu_channels)
        --Conv1D(32,5)->BN->ReLU->Conv1D(64,5)->GlobalAvgPool->Dropout(0.5)--> imu_64
      concat(image_128, imu_64) --Dense(128, relu)--> Dense(n_classes, softmax)

    image_feature_dim is read from the actual cached feature vectors at call
    time (25088-d paper-faithful VGG16-conv-flatten, or 1024-d in the no-
    keras 32x32-flatten fallback -- see train_hand_classifier.extract_
    features) rather than assumed, since it depends on which optional deps
    are installed. The IMU branch mirrors imu_sequence._train_conv1d's
    architecture up to (not including) its softmax head, so it starts from
    the same proven shape as the shipped IMU-only model.

    Compiled with Adam / sparse_categorical_crossentropy, ready for .fit().
    """
    try:
        from tensorflow import keras as tfkeras
        Input, layers, Model = tfkeras.Input, tfkeras.layers, tfkeras.Model
    except Exception:
        import keras as k
        Input, layers, Model = k.Input, k.layers, k.Model

    img_in = Input(shape=(image_feature_dim,), name="image_features")
    img_x = layers.Dense(128, activation="relu", name="image_projection")(img_in)

    imu_in = Input(shape=(imu_window, imu_channels), name="imu_window")
    imu_x = layers.Conv1D(32, 5, padding="same")(imu_in)
    imu_x = layers.BatchNormalization()(imu_x)
    imu_x = layers.ReLU()(imu_x)
    imu_x = layers.Conv1D(64, 5, padding="same")(imu_x)
    imu_x = layers.GlobalAveragePooling1D(name="imu_embedding")(imu_x)
    imu_x = layers.Dropout(0.5)(imu_x)

    fused = layers.Concatenate()([img_x, imu_x])
    fused = layers.Dense(128, activation="relu")(fused)
    out = layers.Dense(n_classes, activation="softmax")(fused)

    model = Model(inputs=[img_in, imu_in], outputs=out)
    model.compile(optimizer="adam", loss="sparse_categorical_crossentropy",
                  metrics=["accuracy"])
    return model


def train_fusion_model(
    img_feats: "np.ndarray", imu_windows: "np.ndarray", labels: "list[str]",
    epochs: int = 10,
):
    """Trains build_fusion_model() end-to-end (image projection + IMU encoder
    + fusion head all update; only the frozen VGG16 backbone that produced
    img_feats does not). Attaches ._hand_classes = sorted(unique labels),
    same convention as train()/train_imu_sequence_model(), so the model is
    savable via train_hand_classifier._save_model unchanged.
    """
    unique_labels = sorted(set(labels))
    label_to_idx = {l: i for i, l in enumerate(unique_labels)}
    y = np.array([label_to_idx[l] for l in labels])

    model = build_fusion_model(
        image_feature_dim=img_feats.shape[1],
        imu_window=imu_windows.shape[1],
        imu_channels=imu_windows.shape[2],
        n_classes=len(unique_labels),
    )
    model.fit([img_feats, imu_windows], y, epochs=epochs, batch_size=32, verbose=0)
    model._hand_classes = unique_labels
    print(f"Trained fusion model  (n={len(labels)}, classes={unique_labels}, "
          f"epochs={epochs})")
    return model


def predict_labels_fusion(
    model, img_feats: "np.ndarray", imu_windows: "np.ndarray", classes: "list[str]"
) -> "list[str]":
    """Decode the fusion model's two-input softmax output to string labels.
    Separate from train_hand_classifier._predict_labels because that
    function's contract is single-input (features: np.ndarray); the fusion
    model takes a [image_features, imu_window] list.
    """
    probs = model.predict([img_feats, imu_windows], verbose=0)
    idx = np.asarray(probs).argmax(axis=1)
    return [classes[i] for i in idx]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestFusionModel -v`
Expected: all 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/fusion_pooled_train.py tests/test_pooled_fusion.py
git commit -m "fusion_pooled_train: add two-branch fusion model architecture"
```

---

### Task 6: Fusion CLI — pooled/LOUO orchestration + `main()`

**Files:**
- Modify: `scripts/fusion_pooled_train.py`
- Modify: `tests/test_pooled_fusion.py`

**Interfaces:**
- Consumes: everything from Tasks 1, 4, 5, plus `hand_dataset.load_dataset_records`,
  `hand_dataset._make_demo_manifest_and_images`, `train_hand_classifier.split_train_eval_indices`,
  `train_hand_classifier._predict_labels`, `train_hand_classifier._save_model`, `imu_sequence.build_sequence_dataset`,
  `imu_sequence.train_imu_sequence_model` (all pre-existing).
- Produces: the CLI entry point — `--pooled`/`--pooled-louo` write
  `<out>/fusion_pooled_/`, `<out>/imu_only_pooled_/`, `<out>/fusion_louo_<key>/`,
  `<out>/imu_only_louo_<key>/`.

- [ ] **Step 1: Write the failing CLI tests**

Append to `tests/test_pooled_fusion.py`:

```python
# ---------------------------------------------------------------------------
# fusion_pooled_train.py: CLI
# ---------------------------------------------------------------------------

class TestFusionCli(unittest.TestCase):

    def _run(self, extra_args, timeout=600):
        script = SCRIPTS_DIR / "fusion_pooled_train.py"
        args = [sys.executable, str(script), "--demo", "--epochs", "1"] + extra_args
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

    def test_requires_pooled_or_louo(self):
        result = self._run([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--pooled", result.stdout + result.stderr)

    def test_pooled_demo_end_to_end(self):
        result = self._run(["--pooled"])
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("=== Pooled ===", result.stdout)

        model_out_line = next(
            l for l in result.stdout.splitlines() if l.startswith("Model out:")
        )
        model_out = Path(model_out_line.split("Model out:", 1)[1].strip())
        for name in ("fusion_pooled_", "imu_only_pooled_"):
            d = model_out / name
            self.assertTrue((d / "hand_model.keras").exists()
                             or (d / "hand_model.pkl").exists(), msg=str(d))
            self.assertTrue((d / "labels.json").exists())

    def test_louo_demo_end_to_end(self):
        result = self._run(["--pooled-louo"])
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("=== Leave-one-user-out ===", result.stdout)
        self.assertIn("held_out='alice|alpha'", result.stdout)
        self.assertIn("held_out='bob|beta'", result.stdout)

        model_out_line = next(
            l for l in result.stdout.splitlines() if l.startswith("Model out:")
        )
        model_out = Path(model_out_line.split("Model out:", 1)[1].strip())
        for prefix in ("fusion_louo_", "imu_only_louo_"):
            for safe_key in ("alice_alpha", "bob_beta"):
                d = model_out / f"{prefix}{safe_key}"
                self.assertTrue((d / "hand_model.keras").exists()
                                 or (d / "hand_model.pkl").exists(), msg=str(d))

    def test_dropped_rows_reported_when_manifest_has_no_imu(self):
        """A manifest with images but zero IMU coverage -> every row dropped,
        script reports it and exits cleanly (0 usable participants after
        filtering) instead of crashing."""
        with tempfile.TemporaryDirectory(prefix="fusion_noimu_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            for i, label in enumerate(["left", "right", "both"]):
                _make_solid_image(img_dir / f"img_{i}.jpg")
            fieldnames = [
                "participant_first", "participant_last", "study_id", "session_id",
                "study_session_index", "captured_at_iso", "holding_hand",
                "image_relative_path", "image_pixel_width", "image_pixel_height",
                "camera_position", "device_model", "system_version", "notes",
            ]
            manifest_path = tmp_path / "manifest.csv"
            with manifest_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                for i, label in enumerate(["left", "right", "both"]):
                    writer.writerow({
                        "holding_hand": label,
                        "image_relative_path": f"hand_images/img_{i}.jpg",
                    })

            script = SCRIPTS_DIR / "fusion_pooled_train.py"
            result = subprocess.run(
                [sys.executable, str(script), str(manifest_path),
                 "--images-root", str(tmp_path), "--pooled", "--epochs", "1"],
                capture_output=True, text=True, timeout=120,
            )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("0 eligible", result.stdout)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestFusionCli -v`
Expected: FAIL — the current `if __name__ == "__main__"` block just prints
"CLI not yet implemented" and exits 1 for every invocation.

- [ ] **Step 3: Replace the placeholder CLI with the real `main()`**

In `scripts/fusion_pooled_train.py`, replace the final block:
```python
if __name__ == "__main__":
    print("fusion_pooled_train.py: CLI not yet implemented (Task 6)", file=sys.stderr)
    sys.exit(1)
```
with:

```python
# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def _fmt(v: float) -> str:
    import math
    return f"{v:.3f}" if not math.isnan(v) else "   nan"


def main() -> None:
    args = _parse_args()

    if not (args.pooled or args.pooled_louo):
        print("Error: pass --pooled and/or --pooled-louo (fusion has no "
              "per-participant mode — see the D1 design's Non-goals).")
        sys.exit(1)

    if args.demo:
        from hand_dataset import _make_demo_manifest_and_images
        tmp = Path(tempfile.mkdtemp(prefix="fusion_demo_"))
        manifest_path, images_root = _make_demo_manifest_and_images(tmp)
        out_dir = tmp / "model"
        print(f"Manifest : {manifest_path}")
        print(f"Images   : {images_root}")
        print(f"Model out: {out_dir}")
    else:
        if not args.manifest:
            print("Error: provide a manifest CSV path, or use --demo")
            sys.exit(1)
        manifest_path = args.manifest
        images_root = args.images_root
        out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    from hand_dataset import load_dataset_records
    all_records = load_dataset_records(manifest_path, images_root)
    kept, dropped = eligible_records(all_records, refresh_cache=args.refresh_cache)
    print(f"Loaded {len(all_records)} records; {len(kept)} eligible "
          f"(both image and IMU readable), {sum(dropped.values())} dropped")
    for p_key, n in sorted(dropped.items()):
        print(f"  dropped {n} row(s) for participant {p_key!r}")

    if not kept:
        print("No eligible rows — nothing to train. Exiting.")
        return

    import imu_sequence
    imu_windows, _imu_labels, _imu_sort_keys = imu_sequence.build_sequence_dataset(
        kept, window=IMU_WINDOW, causal=IMU_CAUSAL
    )
    img_feats = np.stack(
        [cached_image_feature(r["image_path"]) for r in kept], axis=0
    )

    participant_to_indices: "dict[str, list[int]]" = {}
    for i, rec in enumerate(kept):
        participant_to_indices.setdefault(rec["participant_key"], []).append(i)

    from train_hand_classifier import split_train_eval_indices, _predict_labels, _save_model

    participant_splits: "dict[str, tuple[list[int], list[int]]]" = {}
    for p_key, p_indices in participant_to_indices.items():
        labels_ = [kept[i]["label"] for i in p_indices]
        keys_ = [kept[i]["sort_key"] for i in p_indices]
        local_train, _local_eval = split_train_eval_indices(keys_, labels_, train_frac=0.8)
        train_labels_here = [labels_[li] for li in local_train]
        if len(set(train_labels_here)) < 2:
            print(f"  skipping participant {p_key!r} (< 2 distinct labels in train split)")
            continue
        abs_train = [p_indices[li] for li in local_train]
        participant_splits[p_key] = (abs_train, p_indices)

    if len(participant_splits) < 2:
        print("Fewer than 2 usable participants after filtering — pooled/LOUO "
              "need at least 2. Nothing to do.")
        return

    import window_grid

    def _train_and_eval(train_idx: "list[int]", eval_idx: "list[int]", tag: str) -> None:
        train_labels = [kept[i]["label"] for i in train_idx]
        fusion_model = train_fusion_model(
            img_feats[train_idx], imu_windows[train_idx], train_labels, epochs=args.epochs
        )
        imu_only_model = imu_sequence.train_imu_sequence_model(
            imu_windows[train_idx], train_labels, epochs=args.epochs
        )
        unique_labels = sorted(set(train_labels))
        eval_labels = [kept[i]["label"] for i in eval_idx]

        fusion_preds = predict_labels_fusion(
            fusion_model, img_feats[eval_idx], imu_windows[eval_idx], unique_labels
        )
        imu_only_preds = _predict_labels(imu_only_model, imu_windows[eval_idx])

        models = {"fusion": fusion_model, "imu_only": imu_only_model}
        for name, preds in (("fusion", fusion_preds), ("imu_only", imu_only_preds)):
            frame_acc = float(np.mean(np.array(preds) == np.array(eval_labels)))
            grid = window_grid.sweep_window_sizes(kept, eval_idx, preds, eval_labels)
            selected = window_grid.select_window(grid)
            win_acc = grid[selected] if selected is not None else float("nan")
            print(f"  [{tag}] {name}: n_train={len(train_idx)} n_eval={len(eval_idx)} "
                  f"frame-acc={frame_acc:.3f} windowed-acc={_fmt(win_acc)} "
                  f"(selected window={selected}s)")
        return models, unique_labels

    def _save(prefix: str, model, unique_labels: "list[str]") -> None:
        p_out_dir = out_dir / prefix
        p_out_dir.mkdir(parents=True, exist_ok=True)
        with (p_out_dir / "labels.json").open("w", encoding="utf-8") as fh:
            json.dump(unique_labels, fh, indent=2)
        _save_model(model, p_out_dir)
        print(f"  saved: {p_out_dir}")

    if args.pooled:
        print("\n=== Pooled ===")
        pooled_train_idx = [i for (t, _e) in participant_splits.values() for i in t]
        pooled_eval_idx = [i for (_t, e) in participant_splits.values() for i in e]
        models, unique_labels = _train_and_eval(pooled_train_idx, pooled_eval_idx, "pooled")
        _save("fusion_pooled_", models["fusion"], unique_labels)
        _save("imu_only_pooled_", models["imu_only"], unique_labels)

    if args.pooled_louo:
        print("\n=== Leave-one-user-out ===")
        for held_out_key in sorted(participant_splits):
            train_idx = [
                i for p_key, (t, _e) in participant_splits.items()
                if p_key != held_out_key for i in t
            ]
            eval_idx = participant_splits[held_out_key][1]  # FULL data
            models, unique_labels = _train_and_eval(
                train_idx, eval_idx, f"LOUO held_out={held_out_key!r}"
            )
            safe_key = re.sub(r"[^a-z0-9]+", "_", held_out_key) or "participant"
            _save(f"fusion_louo_{safe_key}", models["fusion"], unique_labels)
            _save(f"imu_only_louo_{safe_key}", models["imu_only"], unique_labels)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest", nargs="?",
        help="Path to the hand manifest CSV. Omit with --demo.",
    )
    parser.add_argument(
        "--images-root", default=".",
        help="Directory that image_relative_path/imu_relative_path values are resolved against.",
    )
    parser.add_argument(
        "--out", default="fusion_model_out",
        help="Output directory for the trained models and labels.json files.",
    )
    parser.add_argument(
        "--demo", action="store_true",
        help="Run end-to-end on synthetic data (no real data needed).",
    )
    parser.add_argument(
        "--pooled", action="store_true",
        help="Train one fusion + one IMU-only model on ALL participants' "
             "pooled train-splits.",
    )
    parser.add_argument(
        "--pooled-louo", action="store_true",
        help="Leave-one-user-out: for each participant, train fusion + "
             "IMU-only models on every OTHER participant's train-split and "
             "evaluate on that participant's FULL data (100%% unseen).",
    )
    parser.add_argument(
        "--epochs", type=int, default=10,
        help="Training epochs for both the fusion and IMU-only models (default 10).",
    )
    parser.add_argument(
        "--refresh-cache", action="store_true",
        help="Recompute cached VGG16 image features instead of reusing "
             "Model-Training-Test/cache/img_features/*.npy.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py::TestFusionCli -v`
Expected: all 4 tests PASS (the `--demo` runs take real wall-clock time — VGG16 +
two Conv1D trainings per participant per mode — allow a few minutes; the 600s
subprocess timeout in `_run` covers this)

- [ ] **Step 5: Run the entire new test file to confirm nothing else broke**

Run: `.venv-ml/bin/python -m pytest tests/test_pooled_fusion.py -v`
Expected: all tests in the file PASS

- [ ] **Step 6: Run the pre-existing test suite to confirm no regression**

Run: `.venv-ml/bin/python -m pytest tests/test_hand_pipeline.py -v 2>&1 | tail -20`
Expected: all pre-existing tests still PASS

- [ ] **Step 7: Commit**

```bash
git add scripts/fusion_pooled_train.py tests/test_pooled_fusion.py
git commit -m "fusion_pooled_train: add pooled/LOUO CLI orchestration"
```

---

### Task 7: Real-data verification, regression check, process log

**Files:**
- None created/modified except the process log entry below (this task is
  verification against real repo data, not new code).

**Interfaces:**
- Consumes: everything from Tasks 1-6, run against the real
  `Model-Training-Test/hand_manifest_combined.csv` (2 participants:
  `anonymous|`, `jimmy|`).

- [ ] **Step 1: Run the recomputed cross-user baseline**

Run: `.venv-ml/bin/python scripts/cross_user_eval.py > /tmp/cross_user_recomputed.txt 2>&1; tail -30 /tmp/cross_user_recomputed.txt`

Expected: completes without error; note the `sel(s)` and windowed-acc values for
the `anonymous_ -> jimmy_` and `jimmy_ -> anonymous_` MOCK USER rows — this is
the recomputed baseline Task 3's LOUO numbers get compared against below.

- [ ] **Step 2: Run `--pooled-louo` on real data and verify the index-set regression invariant**

Run:
```bash
.venv-ml/bin/python scripts/train_hand_classifier.py \
    Model-Training-Test/hand_manifest_combined.csv \
    --images-root Model-Training-Test/ \
    --out /tmp/pooled_louo_real/ \
    --imu-seq --imu-causal --imu-window 50 --epochs 30 --pooled --pooled-louo \
    2>&1 | tee /tmp/pooled_louo_real.log
```

Expected: completes without error (this takes real wall-clock time — 3
training runs: 1 pooled + 2 LOUO, ~30 epochs each). In the LOUO section, confirm
`n_train` for `held_out='jimmy|'` equals the committed `anonymous_` model's
`n_train` (1,798, per `Model-Training-Test/models/summary.json`) and `n_eval`
equals `jimmy|`'s full known-label frame count (1,041); symmetrically for
`held_out='anonymous|'` (`n_train=831`, `n_eval=2,249`) — this is the exact,
deterministic regression check the design doc specifies (index-set equality,
not accuracy equality; see the design doc's Testing/validation plan). The
`frame-acc`/`windowed-acc` numbers will be CLOSE to but not identical to
`cross_user_eval.py`'s numbers (stochastic training, no fixed seed) — a large
gap (not a small one) on matching `n_train`/`n_eval` would indicate a bug.

- [ ] **Step 3: Run the fusion model's `--pooled-louo` on real data**

Run:
```bash
.venv-ml/bin/python scripts/fusion_pooled_train.py \
    Model-Training-Test/hand_manifest_combined.csv \
    --images-root Model-Training-Test/ \
    --out /tmp/fusion_real/ \
    --pooled --pooled-louo --epochs 30 \
    2>&1 | tee /tmp/fusion_real.log
```

Expected: completes without error (this is the slowest run — VGG16 feature
extraction over every eligible frame the FIRST time, cached after; note the
"dropped" counts printed near the top — with the current manifest, expect 0
dropped since every existing session that has any IMU coverage has full
coverage, but confirm rather than assume). Note the `windowed-acc` for
`fusion` vs `imu_only` in each `LOUO held_out=...` block.

- [ ] **Step 4: Confirm the feature cache actually saves the second run time**

Note the wall-clock time Step 3 took (the shell's own elapsed time, or wrap it
with `time` if not already noted). Then re-run the exact same command from
Step 3 (same `--out` path is fine — pooled/LOUO models are deterministically
named per participant, so a rerun just overwrites them):

```bash
time .venv-ml/bin/python scripts/fusion_pooled_train.py \
    Model-Training-Test/hand_manifest_combined.csv \
    --images-root Model-Training-Test/ \
    --out /tmp/fusion_real_rerun/ \
    --pooled --pooled-louo --epochs 30 \
    2>&1 | tee /tmp/fusion_real_rerun.log
```

Expected: the "Loaded N records; M eligible ... K dropped" line matches Step 3's
exactly (same manifest, same filter — deterministic), and the rerun completes
noticeably faster than Step 3 (the VGG16/segmentation stage is skipped entirely
on a cache hit — see `cached_image_feature`; only the two Conv1D-based training
loops still run, since keras training isn't cached). This confirms Task 4's
feature cache (`Model-Training-Test/cache/img_features/*.npy`) is actually being
read on the second run, not silently recomputing every time.

- [ ] **Step 5: Compare fusion vs IMU-only per the decision gate**

Per the design doc's "Decision gate" section: read `/tmp/fusion_real.log` and
compare, for each held-out participant, the `fusion` row's windowed-acc against
the `imu_only` row's windowed-acc (both computed in the SAME run, on the SAME
row-eligibility-filtered eval set — this is the apples-to-apples comparison the
design exists to produce). Also compare the pooled/LOUO `imu_only` windowed-acc
from this run against the recomputed baseline from Step 1 — if it beats the
baseline, pooling clears the gate; note that with only 2 participants,
`--pooled-louo`'s LOUO train set is mathematically identical to the single-user
baseline's training data (see the design doc's Context section), so THIS
specific check is expected to be a close call, not a clear win — pooling's real
test arrives with a 3rd participant (Part C).

- [ ] **Step 6: Write the process log entry**

Create `.claude/process/2026-07-20-pooled-fusion-training.md`:

```markdown
# 2026-07-20 — Pooled + LOUO training + IMU/silhouette fusion (D1 implementation)

## What was attempted
Implement the design in docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md:
pooled + leave-one-user-out (LOUO) training for the IMU-only model, a new
IMU+silhouette fusion model with the same modes, and a fix to the windowed-
accuracy metric (was silently calibrated to the old 2Hz/30-frame cadence).

## What was done
[fill in: summarize scripts/window_grid.py, the cross_user_eval.py rewiring,
train_hand_classifier.py --pooled/--pooled-louo, fusion_pooled_train.py, and
the real-data numbers from Steps 1-4 above -- exact windowed-acc/frame-acc
values, selected window sizes, dropped-row counts, and whether fusion beat
IMU-only on this run]

## Errors hit / gotchas
[fill in: anything that came up during real-data verification not caught by
the demo-based tests]

## Key facts for future agents
- With only 2 participants, LOUO ≡ single-user cross-user transfer
  (mathematically, not just empirically -- see the design doc's Context
  section). The pooling question needs a 3rd participant (Part C,
  scripts/merge_hand_export.sh) to mean anything beyond what
  cross_user_eval.py already measured.
- windowed_accuracy()'s window_size is STILL a raw frame count -- unchanged,
  still the right choice for that low-level function. Callers now compute
  the count via scripts/window_grid.py from each session's OWN measured
  capture rate, not a hardcoded 2Hz/30Hz assumption -- this survives any
  future capture-rate change with no further code edits.

## Outcome
[fill in: PASS/gate result, what's next -- e.g. "waiting on a 3rd
participant's export before pooling's result is meaningful" or "fusion beat
IMU-only cross-user by N points, worth pursuing further"]
```

Fill in the bracketed sections with the actual output from Steps 1-4 before
committing.

- [ ] **Step 7: Commit**

```bash
git add .claude/process/2026-07-20-pooled-fusion-training.md
git commit -m "Log D1 pooled/LOUO/fusion real-data verification run"
```

Note: `Model-Training-Test/models/summary.json` / `model.md`'s results log are
**not** touched by this task — per the design doc, this run's numbers are
provisional with only 2 participants, and updating the project's headline
results log is a separate decision for Jimmy to make explicitly, not an
automatic side effect of running verification.
