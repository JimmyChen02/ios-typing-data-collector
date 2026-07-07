#!/usr/bin/env python3
"""
tests/test_hand_pipeline.py
---------------------------
Automated tests for the HandyTrak Python scaffold:
  - scripts/hand_dataset.py
  - scripts/train_hand_classifier.py

Covers: happy path, spec-named edge cases, and at least one failure mode.
Run from the repo root:
    python3 -m pytest tests/test_hand_pipeline.py -v
or:
    python3 tests/test_hand_pipeline.py
"""

from __future__ import annotations

import csv
import json
import os
import pickle
import subprocess
import sys
import tempfile
import unittest
import warnings
from pathlib import Path

# ---------------------------------------------------------------------------
# Ensure scripts/ is importable
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import hand_dataset as hd
import train_hand_classifier as thc


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _make_solid_image(path: Path, color=(200, 100, 100), size=(64, 64)) -> None:
    """Write a tiny solid-colour JPEG at *path* (requires Pillow)."""
    from PIL import Image
    img = Image.new("RGB", size, color=color)
    img.save(str(path), format="JPEG", quality=80)


def _write_manifest(path: Path, rows: list[dict]) -> None:
    fieldnames = [
        "participant_first", "participant_last", "study_id", "session_id",
        "study_session_index", "captured_at_iso", "holding_hand",
        "image_relative_path", "image_pixel_width", "image_pixel_height",
        "camera_position", "device_model", "system_version", "notes",
    ]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            # Fill in defaults for omitted columns
            full = {k: row.get(k, "") for k in fieldnames}
            writer.writerow(full)


# ---------------------------------------------------------------------------
# hand_dataset.py tests
# ---------------------------------------------------------------------------

class TestHandDataset(unittest.TestCase):

    # -----------------------------------------------------------------------
    # Happy path: --demo
    # -----------------------------------------------------------------------
    def test_demo_returns_expected_counts(self):
        """--demo generates 2 participants x 3 conditions x 20 frames = 120 samples."""
        with tempfile.TemporaryDirectory(prefix="hd_test_") as tmp:
            tmp_path = Path(tmp)
            manifest_path, images_root = hd._make_demo_manifest_and_images(tmp_path)
            image_paths, labels = hd.load_dataset(manifest_path, images_root)

        self.assertEqual(len(image_paths), 120, "Expected 120 demo samples")
        self.assertEqual(labels.count("left"),  40)
        self.assertEqual(labels.count("right"), 40)
        self.assertEqual(labels.count("both"),  40)

    def test_demo_images_are_real_files(self):
        """All returned image_paths must point to existing files."""
        with tempfile.TemporaryDirectory(prefix="hd_test_") as tmp:
            tmp_path = Path(tmp)
            manifest_path, images_root = hd._make_demo_manifest_and_images(tmp_path)
            image_paths, _ = hd.load_dataset(manifest_path, images_root)
            for p in image_paths:
                self.assertTrue(Path(p).exists(), f"Missing image: {p}")

    # -----------------------------------------------------------------------
    # Happy path: real manifest with valid images
    # -----------------------------------------------------------------------
    def test_load_real_manifest_three_classes(self):
        """Loading a hand-crafted manifest with 3 classes returns correct counts."""
        with tempfile.TemporaryDirectory(prefix="hd_test_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()

            rows = []
            for i, label in enumerate(["left", "right", "both"]):
                fname = f"img_{i:04d}.jpg"
                _make_solid_image(img_dir / fname)
                rows.append({
                    "holding_hand": label,
                    "image_relative_path": f"hand_images/{fname}",
                })
            manifest_path = tmp_path / "manifest.csv"
            _write_manifest(manifest_path, rows)

            image_paths, labels = hd.load_dataset(str(manifest_path), str(tmp_path))

        self.assertEqual(len(image_paths), 3)
        self.assertIn("left",  labels)
        self.assertIn("right", labels)
        self.assertIn("both",  labels)

    # -----------------------------------------------------------------------
    # Spec edge case: missing image → skip with warning, not crash
    # -----------------------------------------------------------------------
    def test_missing_image_skipped_with_warning(self):
        """Row pointing at a non-existent image is skipped; no exception raised."""
        with tempfile.TemporaryDirectory(prefix="hd_test_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()

            # One valid image
            _make_solid_image(img_dir / "good.jpg")
            # One row with a missing image path
            rows = [
                {"holding_hand": "left", "image_relative_path": "hand_images/good.jpg"},
                {"holding_hand": "right", "image_relative_path": "hand_images/MISSING.jpg"},
            ]
            manifest_path = tmp_path / "manifest.csv"
            _write_manifest(manifest_path, rows)

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                image_paths, labels = hd.load_dataset(str(manifest_path), str(tmp_path))

        # Only the valid image survives
        self.assertEqual(len(image_paths), 1)
        self.assertEqual(labels, ["left"])

        # A warning was issued mentioning the missing file
        warning_messages = [str(w.message) for w in caught]
        self.assertTrue(
            any("MISSING.jpg" in m or "not found" in m for m in warning_messages),
            f"Expected a 'not found' warning; got: {warning_messages}",
        )

    # -----------------------------------------------------------------------
    # Spec edge case: label-only row (empty image_relative_path) is skipped silently
    # -----------------------------------------------------------------------
    def test_label_only_rows_skipped(self):
        """Rows with no image_relative_path are silently skipped."""
        with tempfile.TemporaryDirectory(prefix="hd_test_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            _make_solid_image(img_dir / "img.jpg")

            rows = [
                {"holding_hand": "left",    "image_relative_path": "hand_images/img.jpg"},
                {"holding_hand": "right",   "image_relative_path": ""},   # label-only
                {"holding_hand": "unknown", "image_relative_path": ""},   # also label-only
            ]
            manifest_path = tmp_path / "manifest.csv"
            _write_manifest(manifest_path, rows)
            image_paths, labels = hd.load_dataset(str(manifest_path), str(tmp_path))

        self.assertEqual(len(image_paths), 1)
        self.assertEqual(labels, ["left"])

    # -----------------------------------------------------------------------
    # Spec edge case: unknown label value → skipped with warning
    # -----------------------------------------------------------------------
    def test_unknown_label_value_skipped(self):
        """Rows with an unrecognised label string are skipped with a warning."""
        with tempfile.TemporaryDirectory(prefix="hd_test_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            _make_solid_image(img_dir / "img.jpg")

            rows = [
                {"holding_hand": "left",    "image_relative_path": "hand_images/img.jpg"},
                {"holding_hand": "cradle",  "image_relative_path": "hand_images/img.jpg"},  # bad
            ]
            manifest_path = tmp_path / "manifest.csv"
            _write_manifest(manifest_path, rows)

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                image_paths, labels = hd.load_dataset(str(manifest_path), str(tmp_path))

        self.assertEqual(len(image_paths), 1)
        self.assertEqual(labels, ["left"])
        self.assertTrue(any("cradle" in str(w.message) for w in caught))

    # -----------------------------------------------------------------------
    # Failure case: manifest file does not exist → FileNotFoundError
    # -----------------------------------------------------------------------
    def test_missing_manifest_raises(self):
        """Passing a path to a non-existent manifest must raise an error."""
        with self.assertRaises((FileNotFoundError, OSError)):
            hd.load_dataset("/tmp/does_not_exist_xyzzy.csv", "/tmp")


# ---------------------------------------------------------------------------
# train_hand_classifier.py tests
# ---------------------------------------------------------------------------

class TestTrainHandClassifier(unittest.TestCase):

    # -----------------------------------------------------------------------
    # Happy path: --demo end-to-end (numpy + Pillow only)
    # -----------------------------------------------------------------------
    def test_demo_runs_end_to_end(self):
        """Full pipeline under --demo produces a pickle model and labels.json."""
        with tempfile.TemporaryDirectory(prefix="thc_test_") as tmp:
            tmp_path = Path(tmp)
            manifest_path, images_root = hd._make_demo_manifest_and_images(tmp_path)
            out_dir = tmp_path / "model"
            out_dir.mkdir()

            image_paths, labels = hd.load_dataset(manifest_path, images_root)

            # Stage 1: preprocess
            images = [thc.preprocess(p) for p in image_paths]
            self.assertEqual(len(images), 120)
            for arr in images:
                self.assertEqual(arr.shape, (224, 224, 3))
                # Values should be in [0, 1]; solid-color demo images won't
                # necessarily reach 1.0 (e.g. max color channel 200 → 0.784).
                self.assertGreaterEqual(float(arr.max()), 0.0)
                self.assertLessEqual(float(arr.max()), 1.0 + 1e-6)
                self.assertGreaterEqual(float(arr.min()), 0.0)

            # Stage 2: segment
            silhouettes = [thc.segment(img) for img in images]
            for s in silhouettes:
                self.assertEqual(s.shape, (224, 224))
                self.assertIn(s.dtype.kind, ("u",))  # uint8

            # Stage 3: extract_features (fallback: 32×32 flatten → 1024-d)
            features_list = [thc.extract_features(s) for s in silhouettes]
            for f in features_list:
                self.assertEqual(f.ndim, 1)
                # Fallback vector is 32*32=1024; paper path is 25088
                self.assertIn(len(f), (1024, 25088))

            import numpy as np
            features = np.stack(features_list, axis=0)

            # Stage 4: train (nearest-centroid guaranteed fallback)
            # Filter unknowns first
            train_mask = [l != "unknown" for l in labels]
            train_features = features[train_mask]
            train_labels = [l for l, m in zip(labels, train_mask) if m]

            model = thc.train(train_features, train_labels)
            self.assertIsNotNone(model)

            # Accuracy
            acc = thc._compute_accuracy(model, train_features, train_labels)
            self.assertGreaterEqual(acc, 0.0)
            self.assertLessEqual(acc, 1.0)

            # Persist model
            pkl_path = out_dir / "hand_model.pkl"
            with pkl_path.open("wb") as fh:
                pickle.dump(model, fh)
            self.assertTrue(pkl_path.exists())

            # Persist labels
            unique_labels = sorted(set(train_labels))
            labels_path = out_dir / "labels.json"
            with labels_path.open("w") as fh:
                json.dump(unique_labels, fh)
            with labels_path.open() as fh:
                loaded = json.load(fh)
            self.assertEqual(loaded, ["both", "left", "right"])

    # -----------------------------------------------------------------------
    # preprocess: output shape and range
    # -----------------------------------------------------------------------
    def test_preprocess_shape_and_range(self):
        """preprocess() must return float32 (224,224,3) with values in [0,1]."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="thc_test_") as tmp:
            img_path = Path(tmp) / "test.jpg"
            _make_solid_image(img_path, color=(128, 64, 32), size=(100, 80))
            arr = thc.preprocess(str(img_path))

        self.assertEqual(arr.shape, (224, 224, 3))
        self.assertEqual(arr.dtype, np.float32)
        self.assertGreaterEqual(float(arr.min()), 0.0)
        self.assertLessEqual(float(arr.max()), 1.0 + 1e-6)

    # -----------------------------------------------------------------------
    # segment: output shape and dtype (fallback path, no torch)
    # -----------------------------------------------------------------------
    def test_segment_shape_and_dtype(self):
        """segment() must return a (224,224) uint8 binary mask."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="thc_test_") as tmp:
            img_path = Path(tmp) / "test.jpg"
            _make_solid_image(img_path)
            arr = thc.preprocess(str(img_path))

        mask = thc.segment(arr)
        self.assertEqual(mask.shape, (224, 224))
        self.assertTrue(mask.dtype == "uint8", f"dtype was {mask.dtype}")
        # All values must be 0 or 255
        unique_vals = set(mask.flatten().tolist())
        self.assertTrue(unique_vals.issubset({0, 255}),
                        f"unexpected mask values: {unique_vals - {0, 255}}")

    # -----------------------------------------------------------------------
    # extract_features: vector length matches fallback (1024) when keras absent
    # -----------------------------------------------------------------------
    def test_extract_features_fallback_length(self):
        """Fallback extract_features returns a 1024-d vector (32×32 flatten)."""
        import numpy as np
        from unittest import mock
        # Build a dummy 224×224 uint8 mask
        mask = (np.random.rand(224, 224) > 0.5).astype("uint8") * 255
        # Force the no-keras fallback so this passes in any environment
        # (in .venv-ml keras IS present and the real VGG16 path returns 25088-d)
        with mock.patch.object(thc, "_try_import_keras", return_value=(None, None)):
            feat = thc.extract_features(mask)
        self.assertEqual(len(feat), 1024, f"Expected 1024-d fallback; got {len(feat)}")

    # -----------------------------------------------------------------------
    # train / nearest-centroid: consistent with train, correct classes stored
    # -----------------------------------------------------------------------
    def test_nearest_centroid_predict_and_score(self):
        """NearestCentroid classifier predict() and score() work after training."""
        import numpy as np
        from unittest import mock
        np.random.seed(42)
        # 3 well-separated clusters
        X = np.vstack([
            np.random.randn(10, 4) + np.array([5, 0, 0, 0]),   # left
            np.random.randn(10, 4) + np.array([0, 5, 0, 0]),   # right
            np.random.randn(10, 4) + np.array([0, 0, 5, 0]),   # both
        ])
        y = ["left"] * 10 + ["right"] * 10 + ["both"] * 10

        # Force the pure-numpy nearest-centroid fallback so this passes in any
        # environment (in .venv-ml keras IS present, so train() would build the
        # HandyNet head — 2 epochs on 30 points lands near chance, not >0.8)
        with mock.patch.object(thc, "_try_import_keras", return_value=(None, None)), \
             mock.patch.object(thc, "_try_import_sklearn", return_value=None):
            model = thc.train(X, y)

        self.assertEqual(sorted(model._hand_classes), ["both", "left", "right"])
        acc = thc._compute_accuracy(model, X, y)
        # Well-separated clusters → near-perfect train accuracy
        self.assertGreater(acc, 0.8, f"Expected high train acc; got {acc:.3f}")

    # -----------------------------------------------------------------------
    # Failure case: no usable training samples (all unknown) exits gracefully
    # -----------------------------------------------------------------------
    def test_train_rejects_fewer_than_two_samples(self):
        """train() with only one label should not crash; nearest-centroid handles it."""
        import numpy as np
        X = np.random.randn(1, 8)
        y = ["left"]
        # Should not raise; degenerate but handled
        model = thc.train(X, y)
        self.assertIsNotNone(model)

    # -----------------------------------------------------------------------
    # Spec edge case: sklearn absent → nearest-centroid fallback (simulated)
    # -----------------------------------------------------------------------
    def test_nearest_centroid_runs_without_sklearn(self):
        """_train_nearest_centroid alone (no sklearn dep) works correctly."""
        import numpy as np
        np.random.seed(0)
        X = np.vstack([
            np.ones((5, 10)) * 0,   # left centroid near 0
            np.ones((5, 10)) * 10,  # right centroid near 10
        ])
        y_idx = np.array([0] * 5 + [1] * 5)
        model = thc._train_nearest_centroid(X, y_idx, ["left", "right"])
        preds = model.predict(X)
        acc = model.score(X, ["left"] * 5 + ["right"] * 5)
        self.assertEqual(acc, 1.0)

    # -----------------------------------------------------------------------
    # Optional: validate labels.json content from demo run end-to-end
    # -----------------------------------------------------------------------
    def test_demo_labels_json_content(self):
        """Full demo writes labels.json containing exactly ['both','left','right']."""
        with tempfile.TemporaryDirectory(prefix="thc_test_") as tmp:
            tmp_path = Path(tmp)
            manifest_path, images_root = hd._make_demo_manifest_and_images(tmp_path)
            image_paths, labels = hd.load_dataset(manifest_path, images_root)

            import numpy as np
            images = [thc.preprocess(p) for p in image_paths]
            silhouettes = [thc.segment(img) for img in images]
            features_list = [thc.extract_features(s) for s in silhouettes]
            features = np.stack(features_list, axis=0)

            train_mask = [l != "unknown" for l in labels]
            train_features = features[train_mask]
            train_labels = [l for l, m in zip(labels, train_mask) if m]

            model = thc.train(train_features, train_labels)

            out_dir = tmp_path / "model"
            out_dir.mkdir()
            unique_labels = sorted(set(train_labels))
            labels_path = out_dir / "labels.json"
            with labels_path.open("w") as fh:
                json.dump(unique_labels, fh)

            with labels_path.open() as fh:
                loaded = json.load(fh)

        self.assertEqual(loaded, ["both", "left", "right"])


# ---------------------------------------------------------------------------
# Pillow-guard message test
# ---------------------------------------------------------------------------

class TestPillowGuard(unittest.TestCase):
    def test_require_pil_message(self):
        """_require_pil() must raise ImportError with 'pip install pillow' when PIL absent."""
        original = hd._PIL_AVAILABLE
        try:
            hd._PIL_AVAILABLE = False
            with self.assertRaises(ImportError) as ctx:
                hd._require_pil()
            self.assertIn("pip install pillow", str(ctx.exception).lower())
        finally:
            hd._PIL_AVAILABLE = original


# ---------------------------------------------------------------------------
# NEW: split_train_eval_indices tests (pure numpy, no optional deps)
# ---------------------------------------------------------------------------

class TestSplitTrainEval(unittest.TestCase):

    def test_split_is_time_ordered_and_unshuffled(self):
        """Single label, sort_keys 0..9, train_frac=0.8 → train=[0..7], eval=[8,9]."""
        sort_keys = list(range(10))
        labels = ["left"] * 10
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            train_idx, eval_idx = thc.split_train_eval_indices(sort_keys, labels, 0.8)
        # All go to train because < 2 samples cannot form an eval split ... wait,
        # n=10 >= 2 so we do get a split.  floor(10*0.8)=8 → train first 8.
        self.assertEqual(train_idx, list(range(8)))
        self.assertEqual(eval_idx, [8, 9])

    def test_split_per_condition(self):
        """Two labels each with 10 frames → 8 train / 2 eval each."""
        sort_keys = list(range(20))
        labels = ["left"] * 10 + ["right"] * 10
        train_idx, eval_idx = thc.split_train_eval_indices(sort_keys, labels, 0.8)
        # Per condition, indices 0-9 are 'left' (in sort order: 0..9), 10-19 'right'
        left_in_train  = [i for i in train_idx  if labels[i] == "left"]
        left_in_eval   = [i for i in eval_idx   if labels[i] == "left"]
        right_in_train = [i for i in train_idx  if labels[i] == "right"]
        right_in_eval  = [i for i in eval_idx   if labels[i] == "right"]
        self.assertEqual(len(left_in_train),  8)
        self.assertEqual(len(left_in_eval),   2)
        self.assertEqual(len(right_in_train), 8)
        self.assertEqual(len(right_in_eval),  2)

    def test_split_singleton_condition_goes_to_train(self):
        """A condition with 1 frame goes to train; warning emitted; eval empty for it."""
        sort_keys = [0, 1, 2, 3, 4, 100]
        labels    = ["left"] * 5 + ["both"]  # 'both' has only 1 frame
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            train_idx, eval_idx = thc.split_train_eval_indices(sort_keys, labels, 0.8)
        # The 'both' singleton must land in train
        self.assertIn(5, train_idx)
        self.assertNotIn(5, eval_idx)
        # A warning about 1 frame must have been emitted
        msgs = [str(w.message) for w in caught]
        self.assertTrue(any("1" in m or "only" in m for m in msgs),
                        f"Expected a singleton warning; got: {msgs}")

    def test_split_empty_input(self):
        """Empty input → ([], [])."""
        train_idx, eval_idx = thc.split_train_eval_indices([], [], 0.8)
        self.assertEqual(train_idx, [])
        self.assertEqual(eval_idx, [])


# ---------------------------------------------------------------------------
# NEW: sliding_window_majority_vote / windowed_accuracy tests
# ---------------------------------------------------------------------------

class TestSlidingWindow(unittest.TestCase):

    def test_sliding_window_majority_vote_basic(self):
        """16 'left' + 16 'right', window_size=30 → 3 windows; first left, last right."""
        import numpy as np
        frames = ["left"] * 16 + ["right"] * 16
        result = thc.sliding_window_majority_vote(frames, window_size=30)
        self.assertEqual(len(result), 32 - 30 + 1)  # 3 windows
        self.assertEqual(result[0], "left")   # window 0-29: 16 left, 14 right
        self.assertEqual(result[-1], "right")  # window 2-31: 14 left, 16 right

    def test_sliding_window_tie_break_alphabetical(self):
        """Tie-break chooses alphabetically first label."""
        # 15 'left' + 15 'right' in window of 30 → tie → 'left' (alphabetically first)
        frames = ["left"] * 15 + ["right"] * 15
        result = thc.sliding_window_majority_vote(frames, window_size=30)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0], "left")

    def test_sliding_window_fewer_than_window(self):
        """Fewer frames than window_size → empty list, warning emitted."""
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            result = thc.sliding_window_majority_vote(["left"] * 5, window_size=30)
        self.assertEqual(result, [])
        msgs = [str(w.message) for w in caught]
        self.assertTrue(any("5" in m or "window" in m or "frame" in m for m in msgs),
                        f"Expected a window-size warning; got: {msgs}")

    def test_windowed_accuracy_fewer_than_window(self):
        """windowed_accuracy with < window_size frames returns nan and warns."""
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            acc = thc.windowed_accuracy(["left"] * 5, ["left"] * 5, window_size=30)
        self.assertTrue(
            acc != acc,  # nan != nan is True
            "Expected nan for fewer frames than window_size"
        )


# ---------------------------------------------------------------------------
# NEW: centroid baseline tests (pure numpy)
# ---------------------------------------------------------------------------

class TestCentroidBaseline(unittest.TestCase):

    def _make_silhouette(self, region: str) -> "np.ndarray":
        """Make a 224×224 uint8 silhouette with foreground block in left/center/right."""
        import numpy as np
        sil = np.zeros((224, 224), dtype=np.uint8)
        if region == "left":
            sil[:, :74] = 255          # left third (~0..74 out of 224)
        elif region == "right":
            sil[:, 150:] = 255         # right third (~150..224)
        elif region == "center":
            sil[:, 74:150] = 255       # center third
        return sil

    def test_centroid_baseline_separates(self):
        """Three distinct silhouettes map to the expected labels."""
        # left-third foreground → centroid_x ~0.17 < 0.42 → 'right'
        left_sil   = self._make_silhouette("left")
        # right-third foreground → centroid_x ~0.83 > 0.58 → 'left'
        right_sil  = self._make_silhouette("right")
        # center-third foreground → centroid_x ~0.5 → 'both'
        center_sil = self._make_silhouette("center")

        self.assertEqual(thc.centroid_baseline_predict(left_sil),   "right")
        self.assertEqual(thc.centroid_baseline_predict(right_sil),  "left")
        self.assertEqual(thc.centroid_baseline_predict(center_sil), "both")

    def test_centroid_baseline_empty_silhouette(self):
        """Empty silhouette (no foreground) returns 'both' with a warning."""
        import numpy as np
        empty = np.zeros((224, 224), dtype=np.uint8)
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            result = thc.centroid_baseline_predict(empty)
        self.assertEqual(result, "both")
        msgs = [str(w.message) for w in caught]
        self.assertTrue(any("foreground" in m or "no " in m for m in msgs),
                        f"Expected an empty-silhouette warning; got: {msgs}")

    def test_centroid_baseline_eval_accuracy(self):
        """centroid_baseline_eval returns float accuracy and non-empty confusion."""
        import numpy as np
        sils = [
            self._make_silhouette("left"),
            self._make_silhouette("right"),
            self._make_silhouette("center"),
        ]
        # true labels matching what predict() should return
        true = ["right", "left", "both"]
        acc, conf = thc.centroid_baseline_eval(sils, true)
        self.assertEqual(acc, 1.0)
        self.assertIsInstance(conf, dict)
        self.assertGreater(len(conf), 0)


# ---------------------------------------------------------------------------
# NEW: load_dataset_records / per-user grouping tests
# ---------------------------------------------------------------------------

class TestLoadDatasetRecords(unittest.TestCase):

    def test_per_user_grouping(self):
        """2-participant manifest → distinct participant_keys, sort_key ascending within each."""
        with tempfile.TemporaryDirectory(prefix="hd_rec_test_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()

            rows = []
            for p_first, p_last in [("Alice", "Alpha"), ("Bob", "Beta")]:
                for idx in range(5):
                    fname = f"{p_first.lower()}_{idx}.jpg"
                    _make_solid_image(img_dir / fname)
                    rows.append({
                        "participant_first": p_first,
                        "participant_last":  p_last,
                        "study_session_index": str(idx),
                        "captured_at_iso": f"2026-01-01T{idx:02d}:00:00Z",
                        "holding_hand": "left",
                        "image_relative_path": f"hand_images/{fname}",
                    })

            manifest_path = tmp_path / "manifest.csv"
            _write_manifest(manifest_path, rows)

            records = hd.load_dataset_records(str(manifest_path), str(tmp_path))

        # Should have 10 records total
        self.assertEqual(len(records), 10)

        # Two distinct participant keys
        keys = set(r["participant_key"] for r in records)
        self.assertEqual(keys, {"alice|alpha", "bob|beta"})

        # sort_key ascending within each participant
        for pkey in keys:
            p_recs = [r for r in records if r["participant_key"] == pkey]
            sort_keys = [r["sort_key"] for r in p_recs]
            # Records are not guaranteed to arrive pre-sorted from the file,
            # but sort_keys must be comparable tuples
            for sk in sort_keys:
                self.assertIsInstance(sk, tuple)
                self.assertEqual(len(sk), 3)


# ---------------------------------------------------------------------------
# NEW: IMU + image fusion (spec.md Part B)
# ---------------------------------------------------------------------------

# Exact 13-column MotionRecorder.swift CSV header (t_ms + 12 channels).
_IMU_HEADER = [
    "t_ms", "attitude_roll", "attitude_pitch", "attitude_yaw",
    "grav_x", "grav_y", "grav_z", "acc_x", "acc_y", "acc_z",
    "rot_x", "rot_y", "rot_z",
]


def _write_imu_csv(path: Path, rows: list[list[float]]) -> None:
    """Write an IMU CSV with the exact 13-column MotionRecorder header."""
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(_IMU_HEADER)
        for row in rows:
            writer.writerow(row)


class TestImuSummaryFeatures(unittest.TestCase):
    """scripts/train_hand_classifier.py::imu_summary_features"""

    # -----------------------------------------------------------------------
    # Happy path: layout is mean/std/min/max per channel, in MotionRecorder
    # column order (t_ms excluded), deterministic values.
    # -----------------------------------------------------------------------
    def test_happy_path_layout_and_values(self):
        """Two known data rows produce exact mean/std/min/max per channel."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="imu_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            # channel values: row1 = i, row2 = i+10 for the i-th channel (0-indexed
            # over the 12 channels, t_ms is channel-agnostic/ignored).
            row1 = [0.0] + [float(i) for i in range(12)]
            row2 = [20.0] + [float(i) + 10.0 for i in range(12)]
            _write_imu_csv(csv_path, [row1, row2])

            feat = thc.imu_summary_features(str(csv_path))

        self.assertEqual(feat.shape, (48,))
        self.assertEqual(feat.dtype, np.float32)

        for i, ch in enumerate(thc._IMU_CHANNELS):
            lo = float(i)
            hi = float(i) + 10.0
            mean, std, mn, mx = feat[i * 4: i * 4 + 4]
            self.assertAlmostEqual(float(mean), (lo + hi) / 2.0, places=4)
            self.assertAlmostEqual(float(std), abs(hi - lo) / 2.0, places=4)  # ddof=0, n=2
            self.assertAlmostEqual(float(mn), lo, places=4)
            self.assertAlmostEqual(float(mx), hi, places=4)

    # -----------------------------------------------------------------------
    # 48-d layout matches _IMU_CHANNELS order / _IMU_FEATURE_DIM constant
    # -----------------------------------------------------------------------
    def test_channel_order_and_dim_constants(self):
        """_IMU_CHANNELS has 12 entries (t_ms excluded); _IMU_FEATURE_DIM == 48."""
        self.assertEqual(len(thc._IMU_CHANNELS), 12)
        self.assertNotIn("t_ms", thc._IMU_CHANNELS)
        self.assertEqual(thc._IMU_CHANNELS, [
            "attitude_roll", "attitude_pitch", "attitude_yaw",
            "grav_x", "grav_y", "grav_z",
            "acc_x", "acc_y", "acc_z",
            "rot_x", "rot_y", "rot_z",
        ])
        self.assertEqual(thc._IMU_FEATURE_DIM, 48)

    # -----------------------------------------------------------------------
    # Edge case: single data row → std == 0 for every channel
    # -----------------------------------------------------------------------
    def test_single_frame_std_is_zero(self):
        """A single data row yields std=0 (population std, n=1) for every channel."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="imu_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            row = [0.0] + [float(i) for i in range(12)]
            _write_imu_csv(csv_path, [row])

            feat = thc.imu_summary_features(str(csv_path))

        for i, ch in enumerate(thc._IMU_CHANNELS):
            std = feat[i * 4 + 1]
            self.assertEqual(float(std), 0.0, f"channel {ch}: expected std=0, got {std}")
            mean, _, mn, mx = feat[i * 4], feat[i * 4 + 1], feat[i * 4 + 2], feat[i * 4 + 3]
            self.assertAlmostEqual(float(mean), float(i), places=4)
            self.assertAlmostEqual(float(mn), float(i), places=4)
            self.assertAlmostEqual(float(mx), float(i), places=4)

    # -----------------------------------------------------------------------
    # Edge case: None path → zeros(48), NaN-safe (no exception)
    # -----------------------------------------------------------------------
    def test_none_path_returns_zeros(self):
        """imu_summary_features(None) returns an all-zero 48-d vector, no crash."""
        import numpy as np
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            feat = thc.imu_summary_features(None)
        self.assertEqual(feat.shape, (48,))
        self.assertTrue(np.all(feat == 0.0))

    # -----------------------------------------------------------------------
    # Edge case: nonexistent file → zeros(48), warns, no crash
    # -----------------------------------------------------------------------
    def test_missing_file_returns_zeros(self):
        """A non-existent IMU path returns zeros(48) with a warning, no exception."""
        import numpy as np
        # Use a fresh reason so this test doesn't depend on warning dedup state
        # from other tests (module-level _warned_imu_reasons is a shared set).
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            feat = thc.imu_summary_features("/nonexistent/does_not_exist_xyzzy.csv")
        self.assertEqual(feat.shape, (48,))
        self.assertTrue(np.all(feat == 0.0))

    # -----------------------------------------------------------------------
    # Edge case: header-only CSV (empty session) → zeros(48)
    # -----------------------------------------------------------------------
    def test_header_only_csv_returns_zeros(self):
        """A header-only IMU CSV (zero data rows) returns zeros(48), no crash."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="imu_test_") as tmp:
            csv_path = Path(tmp) / "empty_session.csv"
            _write_imu_csv(csv_path, [])  # header only, no rows

            with warnings.catch_warnings(record=True):
                warnings.simplefilter("always")
                feat = thc.imu_summary_features(str(csv_path))

        self.assertEqual(feat.shape, (48,))
        self.assertTrue(np.all(feat == 0.0))

    # -----------------------------------------------------------------------
    # NaN-safety: non-numeric cells are skipped per-cell, not fatal
    # -----------------------------------------------------------------------
    def test_non_numeric_cells_skipped_not_fatal(self):
        """Non-numeric cell values are skipped per-cell; the row/file is not fatal."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="imu_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            with csv_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh)
                writer.writerow(_IMU_HEADER)
                # attitude_roll has a garbage value on row 1 but a valid one on row 2
                writer.writerow([0.0, "NaN_GARBAGE", 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0])
                writer.writerow([20.0, 5.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0])

            feat = thc.imu_summary_features(str(csv_path))

        # No exception; result is finite everywhere
        self.assertTrue(np.all(np.isfinite(feat)))
        # attitude_roll (channel 0): only the valid 5.0 value should count
        roll_mean = feat[0]
        self.assertAlmostEqual(float(roll_mean), 5.0, places=4)

    # -----------------------------------------------------------------------
    # Edge case: missing expected column → that channel's 4 stats are 0
    # -----------------------------------------------------------------------
    def test_missing_expected_column_zeros_that_channel(self):
        """A CSV missing one expected IMU column yields zeros for that channel only."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="imu_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            header = [h for h in _IMU_HEADER if h != "rot_z"]  # drop rot_z
            with csv_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh)
                writer.writerow(header)
                writer.writerow([0.0] + [1.0] * (len(header) - 1))
                writer.writerow([20.0] + [3.0] * (len(header) - 1))

            feat = thc.imu_summary_features(str(csv_path))

        rot_z_idx = thc._IMU_CHANNELS.index("rot_z")
        rot_z_stats = feat[rot_z_idx * 4: rot_z_idx * 4 + 4]
        self.assertTrue(np.all(rot_z_stats == 0.0))
        # A present channel should have picked up real values
        roll_idx = thc._IMU_CHANNELS.index("attitude_roll")
        self.assertAlmostEqual(float(feat[roll_idx * 4]), 2.0, places=4)  # mean(1,3)


class TestUseImuFusion(unittest.TestCase):
    """--use-imu concatenation / feature-dim / centroid-mode-ignore behavior."""

    def test_use_imu_concatenation_adds_exactly_48_dims(self):
        """img_feat concatenated with imu_summary_features grows dim by exactly 48."""
        import numpy as np
        mask = (np.random.rand(224, 224) > 0.5).astype("uint8") * 255
        img_feat = thc.extract_features(mask)
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            imu_feat = thc.imu_summary_features(None)
        fused = np.concatenate([img_feat, imu_feat])
        self.assertEqual(len(fused), len(img_feat) + 48)

    def test_demo_train_hand_classifier_use_imu_flag_cli(self):
        """`train_hand_classifier.py --demo --use-imu` runs end-to-end via CLI,
        printing the ON banner and completing without error."""
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--use-imu", "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("IMU fusion: ON (48-d)", result.stdout)

    def test_demo_train_hand_classifier_without_use_imu_flag_cli(self):
        """Without --use-imu, the OFF banner prints and the run still succeeds."""
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("IMU fusion: OFF", result.stdout)

    def test_use_imu_with_centroid_mode_ignored_no_error(self):
        """--use-imu with --mode centroid completes normally; IMU has no effect
        (centroid path doesn't use `features_arr` at all).

        Note: stderr may contain a benign, internally-caught traceback from the
        optional tensorflow/keras import probe (`_try_import_keras`, which
        catches all exceptions and returns None on failure) — that is a
        pre-existing environment quirk unrelated to --use-imu, so we assert on
        exit code and stdout content rather than stderr being clean.
        """
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--use-imu",
             "--mode", "centroid", "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("IMU fusion: ON (48-d)", result.stdout)
        # Centroid summary must still be produced (proves the run reached the end)
        self.assertIn("Summary written to:", result.stdout)

    def test_summary_rows_record_fusion_flag(self):
        """summary.json rows include imu_fusion: true/false matching the CLI flag."""
        with tempfile.TemporaryDirectory(prefix="thc_cli_") as tmp:
            script = SCRIPTS_DIR / "train_hand_classifier.py"
            out_dir = Path(tmp) / "out"
            result = subprocess.run(
                [sys.executable, str(script), "--demo", "--use-imu",
                 "--epochs", "1", "--out", str(out_dir)],
                capture_output=True, text=True, timeout=300,
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            # --demo overrides --out with its own tmp dir per main(); locate the
            # summary.json path the run actually reported instead of assuming out_dir.
            m = None
            for line in result.stdout.splitlines():
                if line.startswith("Summary written to:"):
                    m = line.split("Summary written to:", 1)[1].strip()
            self.assertIsNotNone(m, msg=result.stdout)
            with open(m, encoding="utf-8") as fh:
                summary = json.load(fh)
        self.assertTrue(len(summary) > 0)
        for row in summary:
            self.assertIn("imu_fusion", row)
            self.assertTrue(row["imu_fusion"] is True)


class TestHandDatasetImuColumn(unittest.TestCase):
    """scripts/hand_dataset.py::load_dataset_records imu_path handling."""

    # -----------------------------------------------------------------------
    # Happy path: 15-column manifest with a real IMU CSV → imu_path resolved
    # -----------------------------------------------------------------------
    def test_imu_path_resolved_when_present_and_exists(self):
        with tempfile.TemporaryDirectory(prefix="hd_imu_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            imu_dir = tmp_path / "imu"
            imu_dir.mkdir()

            _make_solid_image(img_dir / "img.jpg")
            imu_csv = imu_dir / "session-1.csv"
            _write_imu_csv(imu_csv, [[0.0] + [1.0] * 12])

            fieldnames = [
                "participant_first", "participant_last", "study_id", "session_id",
                "study_session_index", "captured_at_iso", "holding_hand",
                "image_relative_path", "imu_relative_path", "image_pixel_width",
                "image_pixel_height", "camera_position", "device_model",
                "system_version", "notes",
            ]
            manifest_path = tmp_path / "manifest.csv"
            with manifest_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerow({
                    "holding_hand": "left",
                    "image_relative_path": "hand_images/img.jpg",
                    "imu_relative_path": "imu/session-1.csv",
                })

            records = hd.load_dataset_records(str(manifest_path), str(tmp_path))

        self.assertEqual(len(records), 1)
        self.assertIsNotNone(records[0]["imu_path"])
        self.assertEqual(Path(records[0]["imu_path"]), imu_csv)

    # -----------------------------------------------------------------------
    # Backward compatibility: legacy 14-column manifest (no imu_relative_path
    # header at all) → imu_path=None for every row, no warning, no crash, row
    # not skipped.
    # -----------------------------------------------------------------------
    def test_legacy_14_column_manifest_backward_compatible(self):
        with tempfile.TemporaryDirectory(prefix="hd_imu_legacy_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            _make_solid_image(img_dir / "img.jpg")

            rows = [{
                "holding_hand": "left",
                "image_relative_path": "hand_images/img.jpg",
            }]
            manifest_path = tmp_path / "manifest.csv"
            _write_manifest(manifest_path, rows)  # 14-column writer (no imu column)

            with open(manifest_path, encoding="utf-8") as fh:
                header_line = fh.readline().strip()
            self.assertNotIn("imu_relative_path", header_line)

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                records = hd.load_dataset_records(str(manifest_path), str(tmp_path))

        self.assertEqual(len(records), 1, "row must not be skipped")
        self.assertIsNone(records[0]["imu_path"])
        imu_warnings = [str(w.message) for w in caught if "imu" in str(w.message).lower()]
        self.assertEqual(imu_warnings, [], f"expected no IMU warnings, got: {imu_warnings}")

    # -----------------------------------------------------------------------
    # Edge case: imu_relative_path column present but file missing on disk
    # → imu_path=None, row NOT skipped (image-only sample remains valid)
    # -----------------------------------------------------------------------
    def test_missing_imu_file_on_disk_not_skipped(self):
        with tempfile.TemporaryDirectory(prefix="hd_imu_missing_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            _make_solid_image(img_dir / "img.jpg")

            fieldnames = [
                "participant_first", "participant_last", "study_id", "session_id",
                "study_session_index", "captured_at_iso", "holding_hand",
                "image_relative_path", "imu_relative_path", "image_pixel_width",
                "image_pixel_height", "camera_position", "device_model",
                "system_version", "notes",
            ]
            manifest_path = tmp_path / "manifest.csv"
            with manifest_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerow({
                    "holding_hand": "right",
                    "image_relative_path": "hand_images/img.jpg",
                    "imu_relative_path": "imu/NONEXISTENT.csv",
                })

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                records = hd.load_dataset_records(str(manifest_path), str(tmp_path))

        self.assertEqual(len(records), 1, "row must not be skipped for missing IMU file")
        self.assertIsNone(records[0]["imu_path"])
        self.assertEqual(records[0]["label"], "right")

    # -----------------------------------------------------------------------
    # Mixed manifest: some rows have IMU, some don't (empty column value)
    # -----------------------------------------------------------------------
    def test_mixed_manifest_some_rows_have_imu(self):
        with tempfile.TemporaryDirectory(prefix="hd_imu_mixed_") as tmp:
            tmp_path = Path(tmp)
            img_dir = tmp_path / "hand_images"
            img_dir.mkdir()
            imu_dir = tmp_path / "imu"
            imu_dir.mkdir()

            _make_solid_image(img_dir / "a.jpg")
            _make_solid_image(img_dir / "b.jpg")
            imu_csv = imu_dir / "sess.csv"
            _write_imu_csv(imu_csv, [[0.0] + [1.0] * 12])

            fieldnames = [
                "participant_first", "participant_last", "study_id", "session_id",
                "study_session_index", "captured_at_iso", "holding_hand",
                "image_relative_path", "imu_relative_path", "image_pixel_width",
                "image_pixel_height", "camera_position", "device_model",
                "system_version", "notes",
            ]
            manifest_path = tmp_path / "manifest.csv"
            with manifest_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerow({
                    "holding_hand": "left",
                    "image_relative_path": "hand_images/a.jpg",
                    "imu_relative_path": "imu/sess.csv",
                })
                writer.writerow({
                    "holding_hand": "right",
                    "image_relative_path": "hand_images/b.jpg",
                    "imu_relative_path": "",
                })

            records = hd.load_dataset_records(str(manifest_path), str(tmp_path))

        self.assertEqual(len(records), 2)
        by_label = {r["label"]: r for r in records}
        self.assertIsNotNone(by_label["left"]["imu_path"])
        self.assertIsNone(by_label["right"]["imu_path"])

    # -----------------------------------------------------------------------
    # Demo end-to-end: --demo produces a 15-column manifest with real IMU CSVs
    # -----------------------------------------------------------------------
    def test_demo_manifest_has_imu_column_and_files(self):
        with tempfile.TemporaryDirectory(prefix="hd_imu_demo_") as tmp:
            tmp_path = Path(tmp)
            manifest_path, images_root = hd._make_demo_manifest_and_images(tmp_path)

            with open(manifest_path, encoding="utf-8") as fh:
                header = fh.readline().strip().split(",")
            self.assertIn("imu_relative_path", header)
            self.assertEqual(len(header), 15)

            records = hd.load_dataset_records(manifest_path, images_root)

        self.assertEqual(len(records), 120)
        # All demo rows reference an IMU CSV that exists on disk
        self.assertTrue(all(r["imu_path"] is not None for r in records))
        # Exactly 6 distinct IMU CSVs (2 participants x 3 conditions)
        distinct_imu = set(r["imu_path"] for r in records)
        self.assertEqual(len(distinct_imu), 6)


class TestExistingManifestsBackwardCompat(unittest.TestCase):
    """Regression: real 14-column manifests under Model-Training-Test/ must
    still load unchanged (imu_path=None, no crash, no row loss)."""

    _MANIFEST_ROOT = REPO_ROOT / "Model-Training-Test"

    def _check_manifest(self, name: str, expected_min_rows: int):
        manifest_path = self._MANIFEST_ROOT / name
        if not manifest_path.exists():
            self.skipTest(f"{manifest_path} not present in this checkout")

        with open(manifest_path, encoding="utf-8") as fh:
            header = fh.readline().strip().split(",")
        self.assertNotIn(
            "imu_relative_path", header,
            f"{name} unexpectedly already has imu_relative_path — "
            "update this test's assumptions",
        )

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            records = hd.load_dataset_records(str(manifest_path), str(self._MANIFEST_ROOT))

        self.assertGreaterEqual(len(records), expected_min_rows)
        self.assertTrue(all(r["imu_path"] is None for r in records))
        imu_warnings = [str(w.message) for w in caught if "imu" in str(w.message).lower()]
        self.assertEqual(imu_warnings, [], f"{name}: unexpected IMU warnings: {imu_warnings}")

    def test_hand_manifest_combined(self):
        self._check_manifest("hand_manifest_combined.csv", expected_min_rows=100)

    def test_hand_manifest_tran(self):
        self._check_manifest("hand_manifest_Tran_.csv", expected_min_rows=50)

    def test_hand_manifest_jimmy_chen(self):
        self._check_manifest("hand_manifest_Jimmy_Chen.csv", expected_min_rows=50)


# ---------------------------------------------------------------------------
# NEW: D1 — scripts/imu_sequence.py
# ---------------------------------------------------------------------------

import imu_sequence as iseq


class TestImuSequenceLoadSeries(unittest.TestCase):
    """imu_sequence.load_imu_series"""

    def test_happy_path_shape_and_values(self):
        """A well-formed IMU CSV loads to (T, 13) float32, columns = [t_ms] + channels."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="iseq_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            row1 = [0.0] + [float(i) for i in range(12)]
            row2 = [20.0] + [float(i) + 10.0 for i in range(12)]
            _write_imu_csv(csv_path, [row1, row2])

            series = iseq.load_imu_series(str(csv_path))

        self.assertIsNotNone(series)
        self.assertEqual(series.shape, (2, 13))
        self.assertEqual(series.dtype, np.float32)
        self.assertEqual(list(series[:, 0]), [0.0, 20.0])
        # Channel columns follow IMU_CHANNELS order (attitude_roll first == index 1)
        self.assertAlmostEqual(float(series[0, 1]), 0.0, places=4)
        self.assertAlmostEqual(float(series[1, 1]), 10.0, places=4)

    def test_none_path_returns_none(self):
        """load_imu_series(None) -> None, never raises."""
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            self.assertIsNone(iseq.load_imu_series(None))

    def test_missing_file_returns_none(self):
        """Nonexistent path -> None, warns, no exception."""
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            result = iseq.load_imu_series("/nonexistent/does_not_exist_xyzzy.csv")
        self.assertIsNone(result)
        self.assertTrue(any("not found" in str(w.message) for w in caught))

    def test_header_only_returns_none(self):
        """Header-only CSV (0 data rows) -> None, warns, no exception."""
        with tempfile.TemporaryDirectory(prefix="iseq_test_") as tmp:
            csv_path = Path(tmp) / "empty.csv"
            _write_imu_csv(csv_path, [])
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                result = iseq.load_imu_series(str(csv_path))
        self.assertIsNone(result)
        self.assertTrue(any("no data rows" in str(w.message) for w in caught))

    def test_non_numeric_row_skipped_not_fatal(self):
        """A row with a non-numeric t_ms is skipped (never raises); other rows load fine."""
        with tempfile.TemporaryDirectory(prefix="iseq_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            with csv_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh)
                writer.writerow(_IMU_HEADER)
                writer.writerow(["GARBAGE"] + [1.0] * 12)  # bad t_ms -> row skipped
                writer.writerow([20.0] + [2.0] * 12)
            series = iseq.load_imu_series(str(csv_path))
        self.assertIsNotNone(series)
        self.assertEqual(series.shape, (1, 13))
        self.assertAlmostEqual(float(series[0, 0]), 20.0, places=4)

    def test_non_numeric_cell_becomes_zero_not_fatal(self):
        """A non-numeric channel cell (with a valid t_ms) becomes 0.0, row kept."""
        with tempfile.TemporaryDirectory(prefix="iseq_test_") as tmp:
            csv_path = Path(tmp) / "sess.csv"
            with csv_path.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh)
                writer.writerow(_IMU_HEADER)
                writer.writerow([0.0, "NaN_GARBAGE"] + [1.0] * 11)
            series = iseq.load_imu_series(str(csv_path))
        self.assertIsNotNone(series)
        self.assertEqual(series.shape, (1, 13))
        # attitude_roll (first channel, column index 1) -> 0.0 fallback
        self.assertEqual(float(series[0, 1]), 0.0)


class TestImuSequenceWindowForTimestamp(unittest.TestCase):
    """imu_sequence.window_for_timestamp"""

    def _make_series(self, n=100, dt=20.0):
        """A synthetic (n, 13) series: t_ms = i*dt, channel c = i (same for all c)."""
        import numpy as np
        t = (np.arange(n) * dt).astype(np.float32)
        chans = np.tile(np.arange(n, dtype=np.float32).reshape(-1, 1), (1, 12))
        return np.concatenate([t.reshape(-1, 1), chans], axis=1).astype(np.float32)

    def test_shape_always_exact_centered(self):
        series = self._make_series()
        win = iseq.window_for_timestamp(series, center_t_ms=1000.0, window=50, causal=False)
        self.assertEqual(win.shape, (50, 12))

    def test_shape_always_exact_causal(self):
        series = self._make_series()
        win = iseq.window_for_timestamp(series, center_t_ms=1000.0, window=50, causal=True)
        self.assertEqual(win.shape, (50, 12))

    def test_causal_window_is_trailing_prev_curr_only(self):
        """Causal window ends at (and includes) the nearest sample; no future samples."""
        series = self._make_series(n=100, dt=20.0)
        # center at t=1000 -> nearest sample index 50 (t=1000)
        win = iseq.window_for_timestamp(series, center_t_ms=1000.0, window=10, causal=True)
        # Trailing 10 samples ending at idx 50: channel values 41..50
        self.assertEqual(list(win[:, 0]), [float(i) for i in range(41, 51)])

    def test_centered_window_includes_future(self):
        """Centered window includes samples both before and after the nearest sample."""
        series = self._make_series(n=100, dt=20.0)
        win = iseq.window_for_timestamp(series, center_t_ms=1000.0, window=10, causal=False)
        # window//2 = 5 before (inclusive of center) + 5 after -> idx 45..54
        self.assertEqual(list(win[:, 0]), [float(i) for i in range(45, 55)])

    def test_out_of_range_timestamp_clamped(self):
        """A center_t_ms far outside the series range clamps to the boundary sample."""
        series = self._make_series(n=100, dt=20.0)
        win_low = iseq.window_for_timestamp(series, center_t_ms=-99999.0, window=10, causal=False)
        win_high = iseq.window_for_timestamp(series, center_t_ms=99999.0, window=10, causal=False)
        # Clamped to the first/last sample -> all rows repeat the boundary value
        self.assertTrue((win_low[:, 0] == win_low[0, 0]).all() or win_low[0, 0] == 0.0)
        self.assertEqual(float(win_high[-1, 0]), 99.0)  # last sample's channel value

    def test_fewer_samples_than_window_padded_by_clamping(self):
        """A series shorter than `window` still returns exactly (window, 12) via clamping."""
        series = self._make_series(n=5, dt=20.0)
        win = iseq.window_for_timestamp(series, center_t_ms=40.0, window=50, causal=False)
        self.assertEqual(win.shape, (50, 12))

    def test_empty_series_returns_zeros(self):
        """None or empty series -> zeros((window, 12))."""
        import numpy as np
        win_none = iseq.window_for_timestamp(None, center_t_ms=0.0, window=50, causal=False)
        self.assertEqual(win_none.shape, (50, 12))
        self.assertTrue(np.all(win_none == 0.0))

        empty = np.zeros((0, 13), dtype=np.float32)
        win_empty = iseq.window_for_timestamp(empty, center_t_ms=0.0, window=50, causal=False)
        self.assertEqual(win_empty.shape, (50, 12))
        self.assertTrue(np.all(win_empty == 0.0))


class TestImuSequenceFeature(unittest.TestCase):
    """imu_sequence.imu_sequence_feature"""

    def test_flatten_true_shape(self):
        import numpy as np
        series = np.tile(np.arange(30, dtype=np.float32).reshape(-1, 1), (1, 13))
        series[:, 0] = np.arange(30, dtype=np.float32) * 20.0  # t_ms column
        feat = iseq.imu_sequence_feature(series, center_t_ms=200.0, window=20, causal=False, flatten=True)
        self.assertEqual(feat.shape, (20 * 12,))

    def test_flatten_false_shape(self):
        import numpy as np
        series = np.tile(np.arange(30, dtype=np.float32).reshape(-1, 1), (1, 13))
        series[:, 0] = np.arange(30, dtype=np.float32) * 20.0
        feat = iseq.imu_sequence_feature(series, center_t_ms=200.0, window=20, causal=False, flatten=False)
        self.assertEqual(feat.shape, (20, 12))

    def test_z_normalized_zero_mean_unit_var_when_variable(self):
        """A channel with real variance in-window normalizes to ~zero mean, ~unit std."""
        import numpy as np
        rng = np.random.default_rng(0)
        n = 60
        t = np.arange(n, dtype=np.float32) * 20.0
        chans = rng.normal(loc=5.0, scale=2.0, size=(n, 12)).astype(np.float32)
        series = np.concatenate([t.reshape(-1, 1), chans], axis=1)
        feat = iseq.imu_sequence_feature(series, center_t_ms=600.0, window=40, causal=False, flatten=False)
        self.assertAlmostEqual(float(feat[:, 0].mean()), 0.0, places=4)
        self.assertAlmostEqual(float(feat[:, 0].std()), 1.0, places=3)

    def test_zero_variance_channel_normalizes_to_zero_no_div_by_zero(self):
        """A constant (zero-variance) channel in-window -> all-zero, no NaN/inf."""
        import numpy as np
        n = 30
        t = np.arange(n, dtype=np.float32) * 20.0
        chans = np.full((n, 12), 3.5, dtype=np.float32)  # constant everywhere
        series = np.concatenate([t.reshape(-1, 1), chans], axis=1)
        feat = iseq.imu_sequence_feature(series, center_t_ms=300.0, window=20, causal=False, flatten=False)
        self.assertTrue(np.all(np.isfinite(feat)))
        self.assertTrue(np.all(feat == 0.0))

    def test_none_series_returns_zeros(self):
        import numpy as np
        feat = iseq.imu_sequence_feature(None, center_t_ms=0.0, window=20, causal=False, flatten=True)
        self.assertEqual(feat.shape, (20 * 12,))
        self.assertTrue(np.all(feat == 0.0))


class TestImuSequenceBuildDataset(unittest.TestCase):
    """imu_sequence.build_sequence_dataset"""

    def test_happy_path_shape_and_grouping(self):
        """Two records sharing one IMU CSV -> (2, window, 12) X, labels/sort_keys parallel."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="iseq_ds_") as tmp:
            tmp_path = Path(tmp)
            imu_csv = tmp_path / "sess.csv"
            rows = [[float(i) * 20.0] + [float(i)] * 12 for i in range(60)]
            _write_imu_csv(imu_csv, rows)

            records = [
                {
                    "imu_path": str(imu_csv), "label": "left",
                    "captured_at_iso": "2026-01-01T00:00:00Z",
                    "sort_key": (0, "2026-01-01T00:00:00Z", "a.jpg"),
                },
                {
                    "imu_path": str(imu_csv), "label": "right",
                    "captured_at_iso": "2026-01-01T00:00:01Z",
                    "sort_key": (1, "2026-01-01T00:00:01Z", "b.jpg"),
                },
            ]
            X, labels, sort_keys = iseq.build_sequence_dataset(records, window=20, causal=False)

        self.assertEqual(X.shape, (2, 20, 12))
        self.assertEqual(labels, ["left", "right"])
        self.assertEqual(len(sort_keys), 2)

    def test_missing_imu_gets_all_zero_window_kept_not_dropped(self):
        """A record whose imu_path is None still appears in X (all-zero window)."""
        import numpy as np
        records = [
            {"imu_path": None, "label": "left",
             "captured_at_iso": "2026-01-01T00:00:00Z",
             "sort_key": (0, "2026-01-01T00:00:00Z", "a.jpg")},
        ]
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            X, labels, sort_keys = iseq.build_sequence_dataset(records, window=10, causal=False)
        self.assertEqual(X.shape, (1, 10, 12))
        self.assertTrue(np.all(X[0] == 0.0))
        self.assertEqual(labels, ["left"])

    def test_session_start_proxy_is_min_captured_at(self):
        """center_t_ms is derived relative to the MIN captured_at_iso in the group."""
        import numpy as np
        with tempfile.TemporaryDirectory(prefix="iseq_ds2_") as tmp:
            tmp_path = Path(tmp)
            imu_csv = tmp_path / "sess.csv"
            # t_ms 0..980 step 20 (50 samples), channel value == sample index
            rows = [[float(i) * 20.0] + [float(i)] * 12 for i in range(50)]
            _write_imu_csv(imu_csv, rows)

            records = [
                {"imu_path": str(imu_csv), "label": "left",
                 "captured_at_iso": "2026-01-01T00:00:00Z",  # session start (t=0)
                 "sort_key": (0, "2026-01-01T00:00:00Z", "a.jpg")},
                {"imu_path": str(imu_csv), "label": "right",
                 "captured_at_iso": "2026-01-01T00:00:01Z",  # +1s -> center_t_ms=1000
                 "sort_key": (1, "2026-01-01T00:00:01Z", "b.jpg")},
            ]
            X, labels, sort_keys = iseq.build_sequence_dataset(records, window=1, causal=True)

        # First record: center_t_ms=0 -> nearest sample idx 0 -> value 0
        self.assertAlmostEqual(float(X[0, 0, 0]), 0.0, places=3)
        # Second record: center_t_ms=1000 -> nearest sample idx 50 (clamped to 49) -> value 49
        self.assertAlmostEqual(float(X[1, 0, 0]), 49.0, places=3)

    def test_empty_records_returns_empty_arrays(self):
        import numpy as np
        X, labels, sort_keys = iseq.build_sequence_dataset([], window=10, causal=False)
        self.assertEqual(X.shape, (0, 10, 12))
        self.assertEqual(labels, [])
        self.assertEqual(sort_keys, [])


class TestImuSequenceTrainModel(unittest.TestCase):
    """imu_sequence.train_imu_sequence_model"""

    def test_happy_path_attaches_hand_classes_and_predicts(self):
        """Trains on separable synthetic windows; predict() returns known labels."""
        import numpy as np
        rng = np.random.default_rng(1)
        n_per_class = 15
        window = 10
        left = rng.normal(loc=-5.0, scale=0.2, size=(n_per_class, window, 12)).astype(np.float32)
        right = rng.normal(loc=5.0, scale=0.2, size=(n_per_class, window, 12)).astype(np.float32)
        X = np.concatenate([left, right], axis=0)
        labels = ["left"] * n_per_class + ["right"] * n_per_class

        model = iseq.train_imu_sequence_model(X, labels, epochs=3)

        self.assertTrue(hasattr(model, "_hand_classes"))
        self.assertEqual(sorted(model._hand_classes), ["left", "right"])

        preds = model.predict(X)
        preds_arr = np.array(preds)
        # Decode however _predict_labels would (mirrors train_hand_classifier logic)
        if preds_arr.ndim == 2:
            pred_labels = [model._hand_classes[i] for i in preds_arr.argmax(axis=1)]
        elif preds_arr.dtype.kind in ("i", "u"):
            pred_labels = [model._hand_classes[i] for i in preds_arr]
        else:
            pred_labels = list(preds_arr)
        acc = float(np.mean(np.array(pred_labels) == np.array(labels)))
        self.assertGreater(acc, 0.8, f"Expected high train acc on separable data; got {acc:.3f}")

    def test_nearest_centroid_seq_directly(self):
        """_NearestCentroidSeqClassifier / _train_nearest_centroid_seq works standalone."""
        import numpy as np
        X = np.concatenate([
            np.zeros((5, 4, 12), dtype=np.float32),
            np.full((5, 4, 12), 10.0, dtype=np.float32),
        ], axis=0)
        y_idx = np.array([0] * 5 + [1] * 5)
        model = iseq._train_nearest_centroid_seq(X, y_idx, ["left", "right"])
        preds = model.predict(X)
        acc = model.score(X, ["left"] * 5 + ["right"] * 5)
        self.assertEqual(acc, 1.0)


class TestImuSeqCliIntegration(unittest.TestCase):
    """train_hand_classifier.py --imu-seq end-to-end via CLI (spec's required demo path)."""

    def test_demo_imu_seq_runs_end_to_end(self):
        """`--demo --imu-seq` must run end-to-end on synthetic data (spec requirement)."""
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--imu-seq", "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("IMU sequence model: ON", result.stdout)
        self.assertIn("Summary written to:", result.stdout)

    def test_demo_imu_seq_causal_runs_end_to_end(self):
        """`--demo --imu-seq --imu-causal` (the serve-matched variant) also runs end-to-end."""
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--imu-seq", "--imu-causal",
             "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("causal=True", result.stdout)

    def test_imu_seq_wins_over_use_imu_when_both_passed(self):
        """--imu-seq and --use-imu together: --imu-seq wins, warning printed to stderr."""
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--imu-seq", "--use-imu",
             "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("IMU sequence model: ON", result.stdout)
        self.assertIn("--imu-seq wins", result.stdout + result.stderr)

    def test_summary_rows_record_imu_seq_flag(self):
        """summary.json rows include imu_seq: true for an --imu-seq run."""
        with tempfile.TemporaryDirectory(prefix="thc_imu_seq_cli_") as tmp:
            script = SCRIPTS_DIR / "train_hand_classifier.py"
            out_dir = Path(tmp) / "out"
            result = subprocess.run(
                [sys.executable, str(script), "--demo", "--imu-seq",
                 "--epochs", "1", "--out", str(out_dir)],
                capture_output=True, text=True, timeout=300,
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            m = None
            for line in result.stdout.splitlines():
                if line.startswith("Summary written to:"):
                    m = line.split("Summary written to:", 1)[1].strip()
            self.assertIsNotNone(m, msg=result.stdout)
            with open(m, encoding="utf-8") as fh:
                summary = json.load(fh)
        self.assertTrue(len(summary) > 0)
        for row in summary:
            self.assertIn("imu_seq", row)
            self.assertTrue(row["imu_seq"] is True)

    def test_mode_centroid_overridden_to_handynet_with_note(self):
        """--imu-seq with --mode centroid is overridden to 'handynet' (printed note), not an error."""
        script = SCRIPTS_DIR / "train_hand_classifier.py"
        result = subprocess.run(
            [sys.executable, str(script), "--demo", "--imu-seq", "--mode", "centroid",
             "--epochs", "1"],
            capture_output=True, text=True, timeout=300,
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("overriding --mode", result.stdout)


# ---------------------------------------------------------------------------
# NEW: D3 — scripts/export_imu_coreml.py (no coremltools installed by design)
# ---------------------------------------------------------------------------

class TestExportImuCoreml(unittest.TestCase):

    def test_missing_coremltools_fails_cleanly_no_traceback(self):
        """Without coremltools installed, the script prints an install hint and
        exits 1 — never a bare ImportError traceback (per D3 spec)."""
        script = SCRIPTS_DIR / "export_imu_coreml.py"
        with tempfile.TemporaryDirectory(prefix="export_coreml_") as tmp:
            fake_model = Path(tmp) / "nope.keras"
            out_path = Path(tmp) / "out.mlpackage"
            result = subprocess.run(
                [sys.executable, str(script), "--model", str(fake_model),
                 "--out", str(out_path)],
                capture_output=True, text=True, timeout=60,
            )
        # Import coremltools directly to decide which branch we expect.
        try:
            import coremltools  # noqa: F401
            has_coremltools = True
        except ImportError:
            has_coremltools = False

        if not has_coremltools:
            self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
            self.assertIn("coremltools is not installed", result.stderr)
            self.assertNotIn("Traceback (most recent call last)", result.stderr)
        else:
            # If coremltools happens to be installed in this environment, the
            # script should instead fail cleanly on the missing model file.
            self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
            self.assertIn("model not found", result.stderr)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2)
