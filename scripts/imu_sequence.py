#!/usr/bin/env python3
"""
imu_sequence.py
----------------
IMU *sequence* (windowed) features for holding-hand classification, extending
the 48-d IMU *summary* fusion path in `train_hand_classifier.py`
(`imu_summary_features`) with a temporal-window feature: instead of
collapsing an entire session's IMU stream to {mean,std,min,max} per channel,
this module extracts a fixed-length window of raw (z-normalized) samples
centered on (or trailing) each photo's capture time — "prev+curr+future"
context around the frame being labeled.

Reuses `_IMU_CHANNELS` ordering from `train_hand_classifier.py` (12 channels,
excludes `t_ms`) and the same MotionRecorder 13-column CSV format
(`Documents/imu/<sessionId>.csv`, one file per session).

Paper-faithful vs. lightweight fallback
----------------------------------------
  train_imu_sequence_model()
    Paper-faithful-analog: keras Conv1D(32,5)->BN->ReLU->Conv1D(64,5)->
                            GlobalAvgPool->Dropout(0.5)->Dense(softmax).
                            Requires: tensorflow / keras.
    Fallback (1):           sklearn LogisticRegression on flattened X.
    Fallback (2):           numpy nearest-centroid on flattened X (guaranteed).

A [PAPER-FAITHFUL] / [FALLBACK] banner (matching train_hand_classifier.py's
style) is left to the caller (train_hand_classifier.py prints it); this
module itself stays silent except for warnings on data problems.

Usage (as a library, from train_hand_classifier.py):
    from imu_sequence import build_sequence_dataset, train_imu_sequence_model
    X, labels, sort_keys = build_sequence_dataset(records, window=50, causal=False)
    model = train_imu_sequence_model(X[train_idx], [labels[i] for i in train_idx])

center_t_ms derivation (approximation, see train_hand_classifier.py comment
at the call site): the manifest does not currently carry a session start
timestamp column, so `build_sequence_dataset` takes the session start as the
MIN `captured_at_iso` among that session's frames, as a proxy. If exactness
is later required, add a `session_start_iso` manifest column — not added now
(flagged in the D1 spec as a deliberate, documented approximation).
"""

from __future__ import annotations

import csv as _csv
import sys
import warnings
from pathlib import Path

# ---------------------------------------------------------------------------
# Required lightweight dependency: numpy
# ---------------------------------------------------------------------------
try:
    import numpy as np
except ImportError:
    raise ImportError("numpy is required.\nInstall with:  pip install numpy")

# ---------------------------------------------------------------------------
# Local helper — reuse _IMU_CHANNELS ordering from train_hand_classifier.py
# so the two feature paths (48-d summary vs. windowed sequence) never drift
# apart. Import guarded: if train_hand_classifier.py cannot be imported for
# any reason (e.g. this module used standalone very early in a fresh checkout)
# fall back to a literal mirror of the same 12-channel order.
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

try:
    from train_hand_classifier import _IMU_CHANNELS as IMU_CHANNELS
except Exception:
    # Mirror — MUST stay identical to train_hand_classifier._IMU_CHANNELS.
    IMU_CHANNELS = [
        "attitude_roll", "attitude_pitch", "attitude_yaw",
        "grav_x", "grav_y", "grav_z",
        "acc_x", "acc_y", "acc_z",
        "rot_x", "rot_y", "rot_z",
    ]

_N_CHANNELS = len(IMU_CHANNELS)  # 12

# ---------------------------------------------------------------------------
# Warn-once bookkeeping (mirrors imu_summary_features's pattern)
# ---------------------------------------------------------------------------
_warned_reasons: set = set()


def _warn_once(reason: str, msg: str) -> None:
    if reason not in _warned_reasons:
        warnings.warn(msg, stacklevel=2)
        _warned_reasons.add(reason)


# ---------------------------------------------------------------------------
# load_imu_series
# ---------------------------------------------------------------------------

def load_imu_series(imu_path: "str | None") -> "np.ndarray | None":
    """Read a MotionRecorder CSV -> float32 array shape (T, 13):
    columns [t_ms] + the 12 channels in IMU_CHANNELS order.

    None / missing / unreadable / header-only -> None (never raise).
    Warns once per distinct failure reason, mirroring imu_summary_features.
    Non-numeric / short rows are skipped per-row (never raise).
    """
    if not imu_path:
        _warn_once("no_path", "load_imu_series: no IMU path provided for "
                   "one or more samples — treating as missing (None).")
        return None

    path = Path(imu_path)
    if not path.exists():
        _warn_once("missing_file", f"load_imu_series: IMU file not found "
                   f"({path}) — treating as missing (None).")
        return None

    rows: list[list[float]] = []
    try:
        with path.open(newline="", encoding="utf-8") as fh:
            reader = _csv.DictReader(fh)
            for row in reader:
                raw_t = row.get("t_ms")
                if raw_t is None:
                    continue
                try:
                    t_val = float(raw_t)
                except (ValueError, TypeError):
                    continue  # skip non-numeric row

                values = [t_val]
                ok = True
                for ch in IMU_CHANNELS:
                    raw = row.get(ch)
                    if raw is None:
                        values.append(0.0)
                        continue
                    try:
                        values.append(float(raw))
                    except (ValueError, TypeError):
                        values.append(0.0)  # skip non-numeric cell -> 0.0
                if ok:
                    rows.append(values)
    except Exception as exc:
        _warn_once("unreadable", f"load_imu_series: could not read IMU CSV "
                   f"({path}): {exc} — treating as missing (None).")
        return None

    if not rows:
        _warn_once("header_only", f"load_imu_series: IMU CSV has no data "
                   f"rows ({path}) — treating as missing (None).")
        return None

    return np.array(rows, dtype=np.float32)


# ---------------------------------------------------------------------------
# window_for_timestamp
# ---------------------------------------------------------------------------

def window_for_timestamp(
    series: "np.ndarray",
    center_t_ms: float,
    window: int = 50,
    causal: bool = False,
) -> "np.ndarray":
    """Return a fixed (window, 12) float32 slice of the 12 channels centered
    (or trailing) on the sample nearest center_t_ms.

    Edge handling: pad by clamping/replicating the boundary sample so the
    shape is ALWAYS exactly (window, 12). Empty series -> zeros((window, 12)).

    causal=False (default): centered window — window//2 samples before the
        nearest sample (inclusive) + the remainder after.
    causal=True: trailing window — the `window` samples ending at (and
        including) the nearest sample (prev+curr only, no future).
    """
    if series is None or series.size == 0:
        return np.zeros((window, _N_CHANNELS), dtype=np.float32)

    t_col = series[:, 0]
    channels = series[:, 1:1 + _N_CHANNELS]
    n = channels.shape[0]

    # Clamp center_t_ms into the series' time range (edge case: photo
    # timestamp outside the IMU series time range).
    t_min, t_max = float(t_col[0]), float(t_col[-1])
    clamped_center = min(max(center_t_ms, t_min), t_max)

    # Nearest sample index to clamped_center via searchsorted (t_col assumed
    # non-decreasing, as MotionRecorder appends frames in capture order).
    idx = int(np.searchsorted(t_col, clamped_center))
    if idx >= n:
        idx = n - 1
    elif idx > 0:
        # searchsorted returns the insertion point; pick whichever of
        # idx-1/idx is numerically closer to clamped_center.
        if abs(t_col[idx - 1] - clamped_center) <= abs(t_col[idx] - clamped_center):
            idx = idx - 1

    if causal:
        start = idx - window + 1
        end = idx + 1  # exclusive
    else:
        half = window // 2
        start = idx - half
        end = start + window  # exclusive; handles odd `window` (extra sample after center)

    # Build the window index list, clamping (replicating boundary sample)
    # for out-of-range indices so the result is ALWAYS exactly `window` long.
    indices = np.clip(np.arange(start, end), 0, n - 1)
    return channels[indices].astype(np.float32)


# ---------------------------------------------------------------------------
# imu_sequence_feature
# ---------------------------------------------------------------------------

def imu_sequence_feature(
    series: "np.ndarray | None",
    center_t_ms: float,
    window: int = 50,
    causal: bool = False,
    flatten: bool = True,
) -> "np.ndarray":
    """Convenience: window_for_timestamp -> per-channel z-normalized ->
    flattened to (window*12,) when flatten else (window, 12).

    series None -> zeros of the corresponding shape (z-norm of an all-zero
    window is itself all-zero, so no special-casing needed post-window).
    """
    win = window_for_timestamp(series, center_t_ms, window=window, causal=causal)

    # Per-channel z-normalization (within this window only — matches the
    # "windowed" framing; a channel with zero variance in-window normalizes
    # to all-zero rather than dividing by zero).
    mean = win.mean(axis=0, keepdims=True)
    std = win.std(axis=0, keepdims=True)
    std_safe = np.where(std > 1e-8, std, 1.0)
    normed = (win - mean) / std_safe
    normed = np.where(std > 1e-8, normed, 0.0).astype(np.float32)

    if flatten:
        return normed.reshape(-1)
    return normed


# ---------------------------------------------------------------------------
# build_sequence_dataset
# ---------------------------------------------------------------------------

def build_sequence_dataset(
    records: list[dict],
    window: int = 50,
    causal: bool = False,
) -> "tuple[np.ndarray, list[str], list]":
    """Group records by session_id (falls back to imu_path when session_id
    is absent from a record — see note below); load each session IMU series
    once; for each record compute
        center_t_ms = (captured_at - session_start_proxy) in ms
    and build its (window, 12) window (NOT flattened — sequence models want
    the (window, 12) shape).

    session_start_proxy: the MIN `captured_at_iso` among the frames that
    share the same IMU series (i.e. the same session), used as a stand-in
    for the session's true MotionRecorder.start() time (see module
    docstring — the manifest doesn't carry a session_start_iso column).

    Returns (X, labels, sort_keys) where X is (N, window, 12) float32,
    labels is list[str] (record["label"], unfiltered — caller filters
    'unknown' same as the image path does), sort_keys is list (record
    ["sort_key"], parallel to X/labels) for the existing time-ordered split.

    Records whose IMU series is missing get an all-zero window (kept,
    warned once).

    Grouping key: prefer `record["imu_path"]` (one CSV per session_id, so
    this is equivalent to grouping by session but works even when a
    `session_id` key isn't present on the record dict — only `imu_path`,
    `captured_at_iso`, `sort_key`, and `label` are required keys here).
    """
    from datetime import datetime, timezone

    def _parse_iso(s: str) -> "datetime | None":
        if not s:
            return None
        try:
            # Accept both 'Z' suffix and offset forms.
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError:
            return None

    # Group record indices by IMU path (None groups together too — those
    # records get an all-zero window regardless of "session").
    groups: "dict[str | None, list[int]]" = {}
    for i, rec in enumerate(records):
        key = rec.get("imu_path")
        groups.setdefault(key, []).append(i)

    n = len(records)
    X = np.zeros((n, window, _N_CHANNELS), dtype=np.float32)
    labels: list[str] = [rec.get("label", "unknown") for rec in records]
    sort_keys: list = [rec.get("sort_key") for rec in records]

    any_missing_imu = False
    for imu_path, idxs in groups.items():
        series = load_imu_series(imu_path) if imu_path else None
        if series is None:
            any_missing_imu = True
            # zeros already in X for these indices — nothing to do.
            continue

        # session_start_proxy = MIN captured_at_iso among this group's frames.
        # Falls back to captured_at_iso == "" (no timestamp) -> center_t_ms=0.
        parsed_times: list["datetime | None"] = []
        for i in idxs:
            rec = records[i]
            iso = rec.get("captured_at_iso", "")
            parsed_times.append(_parse_iso(iso))

        valid_times = [t for t in parsed_times if t is not None]
        session_start = min(valid_times) if valid_times else None

        for local_i, i in enumerate(idxs):
            t = parsed_times[local_i]
            if t is None or session_start is None:
                center_t_ms = 0.0
            else:
                center_t_ms = (t - session_start).total_seconds() * 1000.0

            X[i] = window_for_timestamp(series, center_t_ms, window=window, causal=causal)

    if any_missing_imu:
        _warn_once("build_missing_imu", "build_sequence_dataset: one or more "
                   "sessions had no readable IMU series — those records use "
                   "an all-zero window (kept, not dropped).")

    return X, labels, sort_keys


# ---------------------------------------------------------------------------
# train_imu_sequence_model
# ---------------------------------------------------------------------------

def _try_import_keras():
    try:
        import tensorflow as tf
        from tensorflow import keras
        return tf, keras
    except Exception:
        try:
            import keras  # standalone keras 3.x
            return None, keras
        except Exception:
            return None, None


def _try_import_sklearn():
    try:
        from sklearn.linear_model import LogisticRegression
        return LogisticRegression
    except Exception:
        return None


class _NearestCentroidSeqClassifier:
    """Pure-numpy nearest-centroid classifier on FLATTENED sequence input
    (guaranteed fallback, mirrors train_hand_classifier._NearestCentroidClassifier)."""

    def __init__(self, centroids: "np.ndarray", classes: list[str]) -> None:
        self.centroids = centroids  # (n_classes, window*12)
        self.classes = classes
        self._hand_classes = classes

    def predict(self, X: "np.ndarray") -> "np.ndarray":
        flat = X.reshape(X.shape[0], -1) if X.ndim > 2 else X
        dists = np.linalg.norm(
            flat[:, np.newaxis, :] - self.centroids[np.newaxis, :, :], axis=2
        )
        return np.array([self.classes[i] for i in np.argmin(dists, axis=1)])

    def score(self, X: "np.ndarray", y_labels: list[str]) -> float:
        preds = self.predict(X)
        return float(np.mean(preds == np.array(y_labels)))


def _train_nearest_centroid_seq(
    X: "np.ndarray", y: "np.ndarray", unique_labels: list[str]
) -> _NearestCentroidSeqClassifier:
    flat = X.reshape(X.shape[0], -1)
    centroids = []
    for idx in range(len(unique_labels)):
        mask = y == idx
        centroid = flat[mask].mean(axis=0) if mask.any() else np.zeros(flat.shape[1])
        centroids.append(centroid)
    centroids_arr = np.stack(centroids, axis=0)
    clf = _NearestCentroidSeqClassifier(centroids_arr, unique_labels)
    print(f"Trained IMU-sequence nearest-centroid  (n={len(y)}, classes={unique_labels})")
    return clf


def _train_conv1d(X: "np.ndarray", y: "np.ndarray", unique_labels: list[str],
                   keras, epochs: int = 10):
    """Conv1D(32,5)->BN->ReLU->Conv1D(64,5)->GlobalAvgPool->Dropout(0.5)->
    Dense(n_classes, softmax). Adam, batch 32."""
    n_classes = len(unique_labels)
    window, n_ch = X.shape[1], X.shape[2]

    try:
        from tensorflow import keras as tfkeras
        Input = tfkeras.Input
        layers = tfkeras.layers
        Model = tfkeras.Model
    except Exception:
        import keras as k
        Input = k.Input
        layers = k.layers
        Model = k.Model

    inp = Input(shape=(window, n_ch))
    x = layers.Conv1D(32, 5, padding="same")(inp)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU()(x)
    x = layers.Conv1D(64, 5, padding="same")(x)
    x = layers.GlobalAveragePooling1D()(x)
    x = layers.Dropout(0.5)(x)
    out = layers.Dense(n_classes, activation="softmax")(x)
    model = Model(inputs=inp, outputs=out)
    model.compile(optimizer="adam",
                  loss="sparse_categorical_crossentropy",
                  metrics=["accuracy"])
    model.fit(X, y, epochs=epochs, batch_size=32, verbose=0)
    model._hand_classes = unique_labels
    print(f"Trained IMU-sequence Conv1D model  (n={len(y)}, classes={unique_labels}, "
          f"epochs={epochs}, batch_size=32, window={window})")
    return model


def train_imu_sequence_model(
    X: "np.ndarray",
    labels: list[str],
    epochs: int = 10,
) -> object:
    """Small temporal classifier. Paper-faithful-analog priority:
      1. keras: Conv1D(32,5)->BN->ReLU->Conv1D(64,5)->GlobalAvgPool->Dropout(0.5)
         ->Dense(n_classes, softmax). Adam, batch 32.
      2. sklearn LogisticRegression on FLATTENED X (fallback).
      3. numpy nearest-centroid on flattened X (guaranteed fallback).
    Attach ._hand_classes = sorted(unique labels), like train_hand_classifier.
    """
    unique_labels = sorted(set(labels))
    label_to_idx = {l: i for i, l in enumerate(unique_labels)}
    y = np.array([label_to_idx[l] for l in labels])

    _, keras = _try_import_keras()
    if keras is not None:
        try:
            return _train_conv1d(X, y, unique_labels, keras, epochs=epochs)
        except Exception as exc:
            warnings.warn(
                f"IMU-sequence Conv1D training failed ({exc}); falling back to "
                "LogisticRegression or nearest-centroid.",
                stacklevel=2,
            )

    LogisticRegression = _try_import_sklearn()
    if LogisticRegression is not None:
        try:
            flat = X.reshape(X.shape[0], -1)
            clf = LogisticRegression(max_iter=1000, multi_class="multinomial",
                                     solver="lbfgs")
            clf.fit(flat, y)
            clf._hand_classes = unique_labels
            # Wrap so callers can call .predict(X) with the (N, window, 12)
            # shape uniformly (mirrors the Conv1D model's calling convention).
            clf._flatten_predict = True
            print(f"Trained IMU-sequence LogisticRegression  (n={len(labels)}, "
                  f"classes={unique_labels})")
            return _FlattenPredictWrapper(clf, unique_labels)
        except Exception as exc:
            warnings.warn(
                f"IMU-sequence LogisticRegression failed ({exc}); falling back "
                "to nearest-centroid.",
                stacklevel=2,
            )

    return _train_nearest_centroid_seq(X, y, unique_labels)


class _FlattenPredictWrapper:
    """Wraps a flat-input sklearn classifier so .predict() accepts the same
    (N, window, 12) shape as the Conv1D model and _NearestCentroidSeqClassifier."""

    def __init__(self, clf, classes: list[str]) -> None:
        self._clf = clf
        self._hand_classes = classes

    def predict(self, X: "np.ndarray") -> "np.ndarray":
        flat = X.reshape(X.shape[0], -1) if X.ndim > 2 else X
        return self._clf.predict(flat)
