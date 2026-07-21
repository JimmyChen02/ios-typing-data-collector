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
from unittest import mock

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
        """A cache hit must NOT recompute; refresh=True must recompute even
        on a hit. mtime alone can't prove this (an unchanged mtime satisfies
        mtime_after >= mtime_before just as well as a real recompute would),
        so this asserts on extract_features() call counts instead."""
        import train_hand_classifier as thc
        with tempfile.TemporaryDirectory(prefix="fusion_img_") as tmp:
            img_path = Path(tmp) / "sample.jpg"
            _make_solid_image(img_path)

            with mock.patch.object(
                thc, "extract_features", wraps=thc.extract_features
            ) as spy:
                self.fpt.cached_image_feature(str(img_path))  # cache miss
                self.assertEqual(spy.call_count, 1)

                self.fpt.cached_image_feature(str(img_path))  # cache hit
                self.assertEqual(spy.call_count, 1)

                self.fpt.cached_image_feature(str(img_path), refresh=True)
                self.assertEqual(spy.call_count, 2)


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
