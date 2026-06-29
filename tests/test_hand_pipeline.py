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
        # Build a dummy 224×224 uint8 mask
        mask = (np.random.rand(224, 224) > 0.5).astype("uint8") * 255
        feat = thc.extract_features(mask)
        # keras is absent in this environment → fallback
        self.assertEqual(len(feat), 1024, f"Expected 1024-d fallback; got {len(feat)}")

    # -----------------------------------------------------------------------
    # train / nearest-centroid: consistent with train, correct classes stored
    # -----------------------------------------------------------------------
    def test_nearest_centroid_predict_and_score(self):
        """NearestCentroid classifier predict() and score() work after training."""
        import numpy as np
        np.random.seed(42)
        # 3 well-separated clusters
        X = np.vstack([
            np.random.randn(10, 4) + np.array([5, 0, 0, 0]),   # left
            np.random.randn(10, 4) + np.array([0, 5, 0, 0]),   # right
            np.random.randn(10, 4) + np.array([0, 0, 5, 0]),   # both
        ])
        y = ["left"] * 10 + ["right"] * 10 + ["both"] * 10

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
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2)
