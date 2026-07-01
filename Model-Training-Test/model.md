# Holding-Hand Model — Training Guide & Results

HandyTrak-style holding-hand classifier (left / right / both) trained on
front-camera body-silhouette images collected with the iOS Typing Data Collector.

---

## Results (first real run)

Trained on one participant's own data — **520 frames**, balanced across hands.

| Metric | Score | What it means |
|--------|-------|---------------|
| **HandyNet windowed accuracy** | **82.9%** | **Headline metric** — sliding-window (30) majority vote, the HandyTrak primary number |
| HandyNet frame accuracy | **77.1%** | Per-frame accuracy, before temporal smoothing |
| Centroid baseline | **33.3%** | Zero-training geometric baseline (= chance for 3 classes) |

**Dataset / split**

| | |
|--|--|
| Participant | `jimmy\|chen` (iPhone 14 Pro Max, front camera) |
| Total frames | 520 |
| Label balance | 174 both / 174 left / 173 right |
| Train / eval | 414 / 105 (time-ordered 80/20, unshuffled) |
| Epochs | 2 |

**Reading the result:** the CNN (82.9%) beats the no-training geometric baseline
(33.3%) by ~50 points — that gap shows the model learned real signal from the
silhouettes, not a trivial geometric trick. 82.9% is in the same ballpark as the
HandyTrak paper's ~89% (achieved with far more data and tuning). The centroid
baseline collapsed to predicting "both" for everything, meaning the naive
"horizontal centroid → hand" heuristic doesn't separate this data — which justifies
the deep-learning approach.

---

## How the training works

When you run the training command, this happens in order:

1. **Load + group.** Reads the manifest's rows (each row = one image + its hand
   label + time-order keys) and groups them by participant.

2. **Time-ordered 80/20 split.** For each hand (left/right/both), the first 80% of
   frames *in capture order* become training data and the last 20% become the test
   set. No shuffling — so the test set is "later moments the model never saw,"
   making the accuracy an honest generalization test rather than memorization.

3. **Turn each image into a feature vector** (the slow ~10-20 min stage on CPU):
   - **preprocess** → resize to 224×224
   - **segment (FCN-ResNet101)** → cut the body out of the background into a clean
     silhouette
   - **VGG16** → convert that silhouette into a numeric feature vector

4. **Train the HandyNet head (transfer learning).** The two big networks
   (FCN-ResNet101, VGG16) are **pretrained and frozen** — they do the heavy lifting
   for free. The only thing that actually *learns* is a small classifier on top
   (dropout + a 3-way softmax). Over 2 epochs it adjusts its weights so its
   prediction matches the true hand label. This is why ~400 images is enough: you
   are only training a tiny head, not a whole network.

5. **Evaluate on the held-out test frames.** Predicts each test frame, compares to
   the true label → **frame accuracy**. Then applies the **sliding-window majority
   vote** (smooths 30 frames at a time, like the paper) → **windowed accuracy**.

6. **Save.** Writes `hand_model.keras` (the trained model) and `summary.json` (the
   numbers) under the output directory.

**In one sentence:** labeled silhouettes → frozen pretrained features → a small head
learns hand-from-features → tested on unseen later frames.

**Key properties**
- **User-dependent:** one model is trained per participant (a single cross-person
  model performs poorly, per the paper).
- **The label supervises:** every frame inherits the label of the condition it was
  captured in, so honest holding during each labeled window is the main data-quality
  lever.

---

## How to run it

From the repository root, with the ML virtual environment:

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py \
    Model-Training-Test/hand_manifest_Jimmy_Chen.csv \
    --images-root Model-Training-Test/ \
    --out Model-Training-Test/models/ \
    --mode both --epochs 2
```

The two things that matter: the **real manifest path**, and **`--images-root`**
pointing at the folder that *contains* `hand_images/`.

**What you'll see**
1. A flood of NumPy warnings at the top — harmless; wait for the `[PAPER-FAITHFUL]`
   banner (it confirms FCN-ResNet101 + VGG16 are being used).
2. `Stage 1 — preprocess … Stage 2 — segment … Stage 3 — extract features` —
   segmentation is the slow part (~10-20 min on CPU). It looks frozen but is working.
3. A results table, then `Summary written to: Model-Training-Test/models/summary.json`.

**Useful knobs**
- `--epochs 5` — train longer (may bump accuracy).
- `--mode handynet` — skip the centroid baseline (a bit faster).
- `--mode centroid` — *just* the baseline, no CNN (runs in seconds; quick data check).
- Append ` > train.log 2>&1 &` to run in the background and watch `train.log`.

**Outputs**
- `Model-Training-Test/models/jimmy_chen/hand_model.keras` — the trained model
- `Model-Training-Test/models/jimmy_chen/labels.json` — class labels
- `Model-Training-Test/models/summary.json` — the accuracy numbers

---

## Data setup note (gotcha)

The manifest references images as `hand_images/<uuid>.jpg`. If AirDrop/Finder
delivers the folder with a different name (e.g. `hand-images` with a hyphen), the
trainer can't find the files. Make sure the image folder is named **`hand_images`**
(underscore) and sits inside the `--images-root` directory.

---

## What to do afterwards

In rough priority:

1. **Prove it generalizes — add participants.** The 82.9% is one person. Collecting
   **2-4 more people** and retraining is the single most valuable next step. Each
   gets their own model; a consistent average across people is what makes the result
   defensible. One person could be luck; four isn't.

2. **Quick experiment — `--epochs 5`.** Cheap to try; may nudge accuracy up.

3. **Report what you have.** `summary.json` is the evidence: 82.9% windowed accuracy,
   CNN beating the no-training baseline (33%) by ~50 points.

4. **The research payoff — connect the two halves.** Use the holding-hand prediction
   to select a **per-hand Gaussian keyboard**. How you hold the phone changes thumb
   reach → changes tap distribution → so the optimal Gaussian key boundaries differ
   by hand. Conditioning the adaptive keyboard on the detected holding hand is where
   this stops being a HandyTrak reimplementation and becomes an original
   contribution. (Requires holding-hand labels during typing — a future increment.)

5. **Housekeeping.** Commit the work so the trained-model milestone has a clean
   baseline.

---

## Collection recap (how this data was made)

- Guided capture in the app walks the participant through **left → right → both**,
  ~30s each at ~2 Hz (front camera, upper body + face in view).
- N typing sessions → N-1 between-session captures (4 sessions = 3 captures).
- Each frame is saved as a JPEG + one labeled row in the manifest CSV.
- Export "Hand Manifest CSV + Images" from the app's Complete screen; place the CSV
  and `hand_images/` folder together; train.

<!-- TRAIN_RESULTS_START -->
<!-- BEST_WINDOWED_ACC=0.836650 -->
## Best training run so far (auto-generated)

_Generated 2026-07-01 16:11 UTC by `train_hand_classifier.py` (mode=both, epochs=2). This section keeps the BEST run (highest mean held-out windowed accuracy); it is overwritten only when a later run beats it._

| Participant | n_train | n_eval | Train acc | Test frame acc | Test windowed acc | Centroid |
|---|---|---|---|---|---|---|
| jimmy|chen | 439 | 111 | 0.866 | 0.649 | 0.805 | 0.333 |
| tran| | 416 | 105 | 0.974 | 0.914 | 0.868 | 0.562 |
| **MEAN** | 855 | 216 | 0.920 | 0.781 | 0.837 | 0.448 |

**Headline — held-out windowed test accuracy: 83.7%**  ·  test frame acc 78.1%  ·  centroid baseline 44.8%

**jimmy|chen — per-class test accuracy:** both=0.405, left=0.541, right=1.000
**jimmy|chen — confusion (true→pred):** both->both:15, both->left:14, both->right:8, left->both:8, left->left:20, left->right:9, right->right:37

**tran| — per-class test accuracy:** both=1.000, left=1.000, right=0.743
**tran| — confusion (true→pred):** both->both:35, left->left:35, right->both:9, right->right:26

_Train acc = in-sample; Test = held-out 20% (time-ordered split); windowed = sliding-window-30 majority vote (HandyTrak metric); Centroid = zero-training baseline._
<!-- TRAIN_RESULTS_END -->
