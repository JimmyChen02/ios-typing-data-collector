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
