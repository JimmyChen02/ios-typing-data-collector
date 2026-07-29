# 2026-07-21 — Batched image-feature caching: negative result

## What was attempted
The fusion feature-cache (`scripts/fusion_pooled_train.py::eligible_records`
→ `cached_image_feature`) processes each image through FCN-ResNet101
(segmentation) then VGG16 (feature extraction) ONE AT A TIME. After the
Jimmy re-capture merge (`.claude/process/2026-07-21-jimmy-recapture-merge.md`)
grew the dataset to 20,236 frames, a cold-cache run was projected at ~61
minutes (measured mid-run: ~252 images/min). Asked whether batching multiple
images per forward pass (the standard deep-learning throughput lever) would
speed this up.

## What was done
1. Added `train_hand_classifier.segment_batch()` / `extract_features_batch()`
   — batched counterparts of the existing `segment()`/`extract_features()`,
   reusing the same lazily-cached FCN-ResNet101/VGG16 models. Purely
   additive; the existing single-image functions are untouched. Verified
   numerically equivalent to N individual calls (exact equality for
   `segment_batch` — FCN's BatchNorm runs in eval mode using stored running
   stats, so it's per-sample-independent regardless of batch size;
   `np.allclose` for `extract_features_batch`, since VGG16 has no BatchNorm
   at all but floating-point summation order can still differ slightly
   across batched vs. sequential tensor ops).
2. Added `fusion_pooled_train.cache_images_batch()`, wired into
   `eligible_records()` by default, with per-batch fallback to
   `cached_image_feature()` if a corrupt image breaks the batched call.
3. **Measured a fair, warm-process, apples-to-apples A/B on real dataset
   images** (same process, models already loaded, adjacent equal-difficulty
   images from the same manifest — not a cold-start-skewed comparison):
   - Single-image (`cached_image_feature()` in a loop): **233 img/min**
   - Batched (`cache_images_batch()`, batch_size=32): **115 img/min**
   - **Batching was ~2x SLOWER, not faster.**

## Why (working explanation, not independently verified further)
This machine has no CUDA/MPS-accelerated inference path in use — FCN-
ResNet101 (torch) and VGG16 (tensorflow/keras) both run on CPU. Batching's
usual win comes from feeding a GPU's otherwise-idle parallel lanes; a
CPU has no equivalent slack to fill by widening the batch. The larger
per-batch working set (N images' worth of activations held at once instead
of one) plausibly exceeds L2/L3 cache and shifts the bottleneck to memory
bandwidth, which does not scale with batch size the way compute does.

## Outcome
**Reverted the wiring.** `eligible_records()` is back to its original
one-image-at-a-time `cached_image_feature()` loop (the empirically faster
path on this hardware) — verified this is the exact pre-batching behavior,
all pre-existing tests pass unchanged. The new batched functions
(`segment_batch`, `extract_features_batch`, `cache_images_batch`) are kept:
correct, tested (including a batch-with-one-corrupt-image isolation test),
and documented as NOT currently used by the default path, with an explicit
note not to re-wire them without re-measuring on the actual target hardware
first. They would very likely help on a GPU-equipped machine (cloud
training, a future Mac with proper MPS-accelerated torch/tensorflow builds,
etc.) — this negative result is specific to CPU-only inference, not a
claim that batching never helps.

**No speedup was found for the caching stage.** The ~252 img/min single-
image rate already observed mid-run is, as far as this investigation went,
close to the practical ceiling on this hardware. The caching is still a
ONE-TIME cost per new image (permanently cached to disk afterward), so this
doesn't block anything — it just means there's no shortcut for the current
run; it needs to finish at its measured rate.

## Key facts for future agents
- Do not assume "batch it" is automatically faster without measuring on the
  actual deployment/dev hardware first — this is a real counterexample, not
  a hypothetical caveat.
- If this pipeline ever runs somewhere with a real GPU, `cache_images_batch()`
  is ready to re-evaluate and re-wire into `eligible_records()` — re-run the
  same fair single-vs-batched A/B methodology used here before flipping the
  default, on THAT hardware.
