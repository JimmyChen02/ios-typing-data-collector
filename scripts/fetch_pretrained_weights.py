#!/usr/bin/env python3
"""
fetch_pretrained_weights.py
---------------------------
Force-download and cache the two pretrained weight sets used by
train_hand_classifier.py so the first real training run is not surprised
by a multi-hundred-MB download mid-pipeline.

FCN-ResNet101 (~200 MB) → torch hub / torchvision cache
VGG16 ImageNet (~500 MB) → ~/.keras/models

Import discipline: heavy libs are imported lazily inside each function
(matching the pattern in train_hand_classifier.py) so this file loads
even when a library is absent.

Usage:
    python scripts/fetch_pretrained_weights.py
    python scripts/fetch_pretrained_weights.py --fcn-only
    python scripts/fetch_pretrained_weights.py --vgg-only
"""

from __future__ import annotations

import argparse
import sys


def fetch_fcn_resnet101() -> None:
    """Construct fcn_resnet101(weights=FCN_ResNet101_Weights.DEFAULT) to force
    the torchvision weight download into the torch hub cache (~200 MB).

    Mirrors EXACTLY the construction in train_hand_classifier.py::_segment_fcn
    (lines ~206-209):
        from torchvision.models.segmentation import fcn_resnet101, FCN_ResNet101_Weights
        weights = FCN_ResNet101_Weights.DEFAULT
        model = fcn_resnet101(weights=weights)
    """
    try:
        import torch  # noqa: F401 — side-effect: validates torch is importable
    except Exception as exc:
        raise ImportError(
            "torch is not installed or not importable.\n"
            "Fix: pip install torch torchvision\n"
            f"Original error: {exc}"
        ) from exc

    try:
        from torchvision.models.segmentation import (
            fcn_resnet101,
            FCN_ResNet101_Weights,
        )
    except Exception as exc:
        raise ImportError(
            "torchvision is not installed or not importable.\n"
            "Fix: pip install torchvision\n"
            f"Original error: {exc}"
        ) from exc

    print("[fetch] FCN-ResNet101: constructing model to trigger weight download ...")
    weights = FCN_ResNet101_Weights.DEFAULT
    model = fcn_resnet101(weights=weights)  # download happens here if not cached
    del model  # free memory; we only needed the download

    # Report cache location
    try:
        import torch.hub as hub
        cache_dir = hub.get_dir()
    except Exception:
        cache_dir = "~/.cache/torch/hub"
    print(f"[fetch] FCN-ResNet101: weights cached. torch hub dir: {cache_dir}")


def fetch_vgg16() -> None:
    """Construct VGG16(weights='imagenet', include_top=False,
    input_shape=(224,224,3)) to force the keras imagenet weight download
    (~500 MB) into ~/.keras/models.

    Mirrors EXACTLY the import fallback in
    train_hand_classifier.py::_features_vgg16 (lines ~266-271):
        try:
            from tensorflow.keras.applications import VGG16
        except ImportError:
            from keras.applications import VGG16
    """
    VGG16 = None
    import_source = None

    try:
        from tensorflow.keras.applications import VGG16
        import_source = "tensorflow.keras.applications"
    except Exception as tf_exc:
        try:
            from keras.applications import VGG16  # type: ignore[no-redef]
            import_source = "keras.applications"
        except Exception as keras_exc:
            raise ImportError(
                "Neither tensorflow nor standalone keras is installed or importable.\n"
                "Fix: pip install tensorflow>=2.16\n"
                f"tensorflow error : {tf_exc}\n"
                f"keras error      : {keras_exc}"
            ) from keras_exc

    print(f"[fetch] VGG16: importing from {import_source}")
    print("[fetch] VGG16: constructing model to trigger imagenet weight download (~500 MB) ...")
    backbone = VGG16(weights="imagenet", include_top=False, input_shape=(224, 224, 3))
    del backbone  # free memory; we only needed the download

    # Report cache location
    try:
        import pathlib
        keras_cache = pathlib.Path.home() / ".keras" / "models"
        print(f"[fetch] VGG16: weights cached. keras models dir: {keras_cache}")
    except Exception:
        print("[fetch] VGG16: weights cached. keras models dir: ~/.keras/models")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Pre-download FCN-ResNet101 and VGG16 pretrained weights."
    )
    parser.add_argument(
        "--fcn-only",
        action="store_true",
        help="Download only FCN-ResNet101 weights (torch hub).",
    )
    parser.add_argument(
        "--vgg-only",
        action="store_true",
        help="Download only VGG16 weights (keras imagenet).",
    )
    args = parser.parse_args()

    do_fcn = not args.vgg_only
    do_vgg = not args.fcn_only

    ok = True

    if do_fcn:
        try:
            fetch_fcn_resnet101()
            print("[fetch] OK  FCN-ResNet101 weights ready.")
        except Exception as exc:
            print(f"[fetch] WARN FCN-ResNet101 failed: {exc}")
            ok = False  # note failure but continue

    if do_vgg:
        try:
            fetch_vgg16()
            print("[fetch] OK  VGG16 weights ready.")
        except Exception as exc:
            print(f"[fetch] WARN VGG16 failed: {exc}")
            ok = False  # note failure but continue

    if ok:
        print("[fetch] All requested weights are cached and ready.")
    else:
        print(
            "[fetch] One or more weight downloads failed (see WARN lines above). "
            "Install the missing library and re-run this script."
        )

    return 0  # always exit 0; WARN lines communicate partial failure


if __name__ == "__main__":
    sys.exit(main())
