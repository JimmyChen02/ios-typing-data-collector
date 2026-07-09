#!/usr/bin/env python3
"""
export_imu_coreml.py
---------------------
Converts a trained IMU SEQUENCE model (D1, `scripts/imu_sequence.py` /
`train_hand_classifier.py --imu-seq`) to a Core ML `.mlpackage` for on-device
live posture inference (D3).

Resolves OPEN QUESTION 1 as **(A) IMU-only Core ML model**: no camera is
needed for live inference. Convert the `--imu-causal` variant (trailing
window — prev+curr only) since that is the only window shape a live,
causal, on-device buffer can compute; the centered window (prev+curr+future)
used for offline training/eval in D1 cannot be reproduced live.

D3 feasibility note
--------------------
The image pipeline (FCN-ResNet101 segmentation + VGG16 feature extraction,
`train_hand_classifier.py`'s HandyNet path) is **NOT** converted for live use
here — both networks are far too heavy for interactive on-device inference
on commodity iPhone hardware. The Core ML export path covers the **IMU
sequence model only** (the small Conv1D/GRU-style classifier from
`imu_sequence.train_imu_sequence_model`).

This realizes the advisor's stated goal that the *deployed* model no longer
depends on the user declaring which hand is holding the phone: at inference
time, the IMU-only model predicts posture from motion alone. The declared
L/R/Both label (from the D2 "Posture training run" capture flow) is used
ONLY as the *training* label — never as a runtime input.

Usage
-----
    .venv-ml/bin/python scripts/export_imu_coreml.py \\
        --model Model-Training-Test/models_imu/<participant_key>/hand_model.keras \\
        --labels Model-Training-Test/models_imu/<participant_key>/labels.json \\
        --window 50 \\
        --out Model-Training-Test/models_imu/<participant_key>/posture_imu.mlpackage

Requires `coremltools` (lazy-imported; see requirements-ml.txt — install into
the isolated `.venv-ml/`, never the anaconda base env). If coremltools is
absent, this script prints a clear installation error and exits non-zero; it
never crashes with a bare ImportError traceback.

Input / output contract
------------------------
Input:  `imu_window`, float32 `(1, window, 12)` — a single causal-trailing
        IMU window in `imu_sequence.IMU_CHANNELS` order, per-channel
        z-normalized exactly like `imu_sequence.imu_sequence_feature(...,
        flatten=False)` (the on-device `PosturePredictor` must apply the
        same normalization before calling predict — see its docstring).
Output: a Core ML classifier — string class label + a `probabilities`
        dictionary (softmax over the trained classes), so
        `PosturePredictor` can read both the predicted `HoldingHand` case
        and a confidence score.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))


def _try_import_coremltools():
    try:
        import coremltools as ct
        return ct
    except ImportError:
        return None


def _load_keras_model(model_path: Path):
    """Load a saved keras model (.keras format, written by
    train_hand_classifier._save_model / imu_sequence's Conv1D path)."""
    try:
        from tensorflow import keras
    except ImportError:
        try:
            import keras
        except ImportError:
            raise ImportError(
                "tensorflow/keras is required to load the trained IMU "
                "sequence model for Core ML conversion.\n"
                "Install with:  pip install tensorflow  (see requirements-ml.txt)"
            )
    return keras.models.load_model(str(model_path))


def export_imu_coreml(
    model_path: str,
    labels_path: "str | None",
    window: int,
    out_path: str,
) -> "str | None":
    """Convert the keras IMU-sequence model at *model_path* to a Core ML
    classifier at *out_path*. Returns the output path on success, None on
    failure (never raises for the "coremltools absent" case — callers using
    this as a library, e.g. a future automated pipeline, can check for None).

    Class labels: read from *labels_path* (labels.json written alongside the
    model by train_hand_classifier._save_model's caller) when given, else
    read from `model._hand_classes` if the loaded keras model carries it
    (it usually won't survive a save/load round-trip as a plain attribute,
    so passing --labels explicitly is the recommended path).
    """
    ct = _try_import_coremltools()
    if ct is None:
        print(
            "export_imu_coreml: coremltools is not installed.\n"
            "Install it into the isolated ML venv:\n"
            "    .venv-ml/bin/pip install 'coremltools>=7.0'\n"
            "(see requirements-ml.txt — do NOT install into the anaconda base env).",
            file=sys.stderr,
        )
        return None

    model_path_p = Path(model_path)
    if not model_path_p.exists():
        print(f"export_imu_coreml: model not found at {model_path_p}", file=sys.stderr)
        return None

    keras_model = _load_keras_model(model_path_p)

    class_labels: "list[str] | None" = None
    if labels_path:
        labels_path_p = Path(labels_path)
        if labels_path_p.exists():
            with labels_path_p.open("r", encoding="utf-8") as fh:
                class_labels = json.load(fh)
        else:
            print(f"export_imu_coreml: --labels file not found at "
                  f"{labels_path_p} — proceeding without class-label metadata "
                  "(Core ML output will be raw softmax indices).",
                  file=sys.stderr)
    if class_labels is None:
        class_labels = getattr(keras_model, "_hand_classes", None)

    # Verify the model's expected input shape matches --window (best-effort;
    # keras Input shape is (None, window, 12) for the Conv1D architecture).
    try:
        input_shape = keras_model.input_shape  # (None, window, 12)
        model_window = input_shape[1]
        if model_window is not None and model_window != window:
            print(f"export_imu_coreml: WARNING — model was trained with "
                  f"window={model_window} but --window={window} was passed; "
                  f"using the model's own window ({model_window}) for the "
                  "Core ML input shape.", file=sys.stderr)
            window = model_window
    except Exception:
        pass  # best-effort only; fall through with the passed --window

    classifier_config = None
    if class_labels:
        classifier_config = ct.ClassifierConfig(class_labels=list(class_labels))

    # coremltools requires the TensorType name to match the TF graph's own
    # placeholder (Keras 3 names it e.g. "input_layer"), so convert with the
    # model's real input name, then rename the feature to the "imu_window"
    # contract PosturePredictor.swift expects.
    try:
        tf_input_name = keras_model.input.name.split(":")[0]
    except Exception:
        tf_input_name = "imu_window"

    mlmodel = ct.convert(
        keras_model,
        source="tensorflow",
        inputs=[ct.TensorType(name=tf_input_name, shape=(1, window, 12))],
        classifier_config=classifier_config,
        convert_to="mlprogram",
    )

    # Rename features to the contract PosturePredictor.swift expects:
    # input "imu_window", probability output "classProbability" (coremltools
    # emits "<softmax layer name>_probs", e.g. "classLabel_probs").
    spec_changed = False
    if tf_input_name != "imu_window":
        ct.utils.rename_feature(mlmodel._spec, tf_input_name, "imu_window")
        spec_changed = True
    probs_name = mlmodel._spec.description.predictedProbabilitiesName
    if probs_name and probs_name != "classProbability":
        ct.utils.rename_feature(mlmodel._spec, probs_name, "classProbability")
        spec_changed = True
    if spec_changed:
        mlmodel = ct.models.MLModel(
            mlmodel._spec, weights_dir=mlmodel.weights_dir
        )

    mlmodel.author = "TypingResearch"
    mlmodel.short_description = (
        "IMU-only holding-hand (posture) classifier — predicts left/right/"
        "both from a causal-trailing window of device-motion samples. "
        "Trained via scripts/train_hand_classifier.py --imu-seq --imu-causal "
        "and scripts/imu_sequence.py."
    )
    mlmodel.input_description["imu_window"] = (
        f"float32 (1, {window}, 12) causal-trailing IMU window, channel order "
        "= imu_sequence.IMU_CHANNELS, RAW sensor values (no normalization — "
        "matches imu_sequence.build_sequence_dataset's training windows)."
    )

    out_path_p = Path(out_path)
    out_path_p.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path_p))
    print(f"Core ML model saved to: {out_path_p}")
    if class_labels:
        print(f"Classes: {class_labels}")
    else:
        print("WARNING: no class labels were embedded (pass --labels "
              "labels.json for a usable classifier).")
    return str(out_path_p)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model", required=True,
        help="Path to the trained keras IMU-sequence model "
             "(hand_model.keras, from --imu-seq --imu-causal training).",
    )
    parser.add_argument(
        "--labels", default=None,
        help="Path to labels.json (ordered class list) written alongside "
             "--model. Strongly recommended — without it the Core ML "
             "output has no class-label metadata.",
    )
    parser.add_argument(
        "--window", type=int, default=50,
        help="IMU window size in samples (default 50). Should match the "
             "--imu-window used at training time; a mismatch vs. the "
             "model's actual input shape is auto-corrected with a warning.",
    )
    parser.add_argument(
        "--out", required=True,
        help="Output path for the Core ML model (.mlpackage recommended for "
             "convert_to='mlprogram').",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    result = export_imu_coreml(
        model_path=args.model,
        labels_path=args.labels,
        window=args.window,
        out_path=args.out,
    )
    if result is None:
        sys.exit(1)


if __name__ == "__main__":
    main()
