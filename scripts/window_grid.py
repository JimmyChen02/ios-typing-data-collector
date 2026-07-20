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
