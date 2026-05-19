# TypingResearch

TypingResearch combines two parts: an iPhone data-collection app for mobile text-entry studies, and companion offline Python scripts for post-study analysis.

The iOS app runs timed HCI study sessions with instrumented custom keyboards in classic and adaptive Gaussian modes, capturing touch coordinates, timing, correction behavior, and accuracy metrics. The Python scripts operate on exported CSVs to clean data, regenerate keyboard-view PDFs, visualize session overlap, and compute trial-level loss analyses.

## iOS App

### What The App Does

- Runs timed typing-study sessions on iPhone with two keyboard modes:
  - `classic`: fixed rectangular hit regions
  - `gaussian`: adaptive per-key probabilistic hit regions
- Supports two study designs:
  - `classic + adaptive`: the first half of sessions use the classic keyboard, and the second half use the Gaussian keyboard
  - `classic only`: all sessions use the classic keyboard
- Lets the researcher choose 2-20 one-minute sessions; mixed-mode studies use an even split between classic and adaptive
- Captures per-keystroke touch coordinates, key geometry, timing, correctness, and correction behavior
- Presents a continuous text stream drawn from rotating sentence corpora and expands the prompt as the participant types
- Starts the session timer on the first keypress instead of on screen load
- Shows in-app summaries for session performance, data cleaning, ground-truth loss, tap distribution, and session overlap
- Exports raw and cleaned keystroke CSVs, plus raw, cleaned, and Gaussian visualization PDFs

### Current Study Design

The app is organized around a multi-session study:

- In `classic + adaptive` mode, the first half of sessions are `classic` and the second half are `gaussian`
- In `classic only` mode, every session remains `classic`
- During classic sessions, valid taps are appended to the persistent Gaussian training corpus
- During gaussian sessions, the adaptive keyboard uses a frozen model fit from the earlier persisted classic-session data
- Optional backend export exists, but it is disabled by default unless `BackendClient.isEnabled` is turned on

### Training Logic

Each fitted key is represented by a 2D Gaussian over centered touch offsets. The current fitting pipeline:

- trains on the `intended` key when an `expectedChar` is available
- converts mistaps from the landed key's coordinate frame into the intended key's frame
- still allows deleted mistaps to train the intended key when an `expectedChar` is known
- includes delete taps as their own touch target
- falls back to accepted correct taps when intended-character supervision is unavailable, while excluding quickly deleted inserts from that fallback path

### Classification Logic

At inference time, the Gaussian keyboard:

- evaluates each candidate key with Mahalanobis log-likelihood
- adds a soft spatial prior outside the key bounds
- uses anchor protection near key centers to avoid unstable boundary stealing
- chooses the winning key by a competitive argmax

### In-App Outputs

After each session or study, the app provides:

- per-session accuracy, WPM, and backspace summaries
- data-cleaning summaries and outlier counts
- ground-truth loss charts computed from clean classic-session insert taps
- tap distribution views and a session-overlap viewer
- file export and optional backend upload

### Available Exports

| Export | Contents |
|--------|----------|
| `Raw Keystrokes CSV` | One row per recorded event with participant/study metadata, session mode and session index, trial metadata, key geometry, timing, and intended/actual/corrected characters |
| `Cleaned Keystrokes CSV` | Raw schema plus `dist_from_target_kw`, `is_outlier`, and `outlier_flags`; rows flagged as `spatial` or `far_from_target` are excluded, while other flagged rows remain annotated |
| `Raw PDF` | Keyboard-view dot plot of recorded taps on the app's standard keyboard layout |
| `Cleaned PDF` | The same keyboard-view PDF with `spatial` and `far_from_target` taps removed |
| `Gaussian PDF` | Rasterized Gaussian decision surface with per-key ellipses and correct-tap overlays, fit from the persisted classic-session corpus |

The Gaussian PDF is shown from adaptive-session summaries because it visualizes the classic-trained model used by the adaptive keyboard.

## Offline Python Scripts

The `scripts/` folder contains companion analysis and export utilities:

- `scripts/clean_keystrokes.py`: flags outliers and produces the cleaned CSV schema used by downstream analyses
- `scripts/keystrokes_to_pdf.py`: renders the keyboard-view PDF from a cleaned CSV
- `scripts/gaussian_keyboard_pdf.py`: mirrors the intended-key Gaussian fitting logic and exports a Gaussian keyboard PDF from a CSV
- `scripts/ground_truth_trial_loss.py`: builds an all-trials ground truth and exports graph-ready loss/similarity CSVs for cumulative-prefix and all-combinations analyses
- `scripts/future-trial-loss.py`: measures how well cumulative classic-trial data predicts future trials
- `scripts/session_overlap_visualization.py`: generates cumulative session-overlap SVGs and weighted-Jaccard summaries
- `scripts/manual_test_ground_truth_trial_loss.py`: produces synthetic/manual test outputs for the ground-truth loss pipeline
- `scripts/loss-automation.py`: legacy overlap-analysis helper retained in the repo but marked unused

Examples:

```sh
python3 scripts/clean_keystrokes.py <keystrokes.csv>
python3 scripts/keystrokes_to_pdf.py <cleaned_keystrokes.csv> [output.pdf]
python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv> [output.pdf]
python3 scripts/ground_truth_trial_loss.py <cleaned_keystrokes.csv>
python3 scripts/future-trial-loss.py <cleaned_keystrokes.csv>
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv>
python3 scripts/manual_test_ground_truth_trial_loss.py --output-dir /tmp/ground-truth-loss-test
```

### To Open The App

```sh
open TypingResearch.xcodeproj
```

## Python Script Reference

Run these commands from the repository root unless noted otherwise.

### 1. Clean an exported keystroke CSV

Adds normalized tap coordinates plus outlier columns. If no output path is
given, the script writes `<input_stem>_cleaned.csv` next to the input file.

```sh
python3 scripts/clean_keystrokes.py <raw_keystrokes.csv>
python3 scripts/clean_keystrokes.py <raw_keystrokes.csv> <cleaned_keystrokes.csv>
```

### 2. Render keyboard tap PDFs

Use this for static PDF inspection of tap distributions or the fitted Gaussian
keyboard.

```sh
python3 scripts/keystrokes_to_pdf.py <cleaned_keystrokes.csv>
python3 scripts/keystrokes_to_pdf.py <cleaned_keystrokes.csv> <tap_distribution.pdf>

python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv>
python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv> <gaussian_keyboard.pdf>
```

### 3. Ground-truth trial loss

Use this to estimate how many trials are enough by comparing trial subsets
against the all-trials ground truth. It writes graph-ready summary CSVs.

```sh
python3 scripts/ground_truth_trial_loss.py <cleaned_keystrokes.csv>
python3 scripts/ground_truth_trial_loss.py <cleaned_keystrokes.csv> --grid-size 50 --label-column expected_char
python3 scripts/manual_test_ground_truth_trial_loss.py --output-dir /tmp/ground-truth-loss-test
```

Primary outputs:

- `<input_stem>_ground_truth_trial_loss_simple_summary.csv`
- `<input_stem>_ground_truth_trial_loss_all_combinations_summary.csv`

### 4. Future-trial loss

Use this when the question is: “If I train on the first N trials, how well does
that predict the remaining future trials?”

```sh
python3 scripts/future-trial-loss.py <cleaned_keystrokes.csv>
python3 scripts/future-trial-loss.py <cleaned_keystrokes.csv> --grid-size 50 --label-column expected_char
```

Primary output:

- `<input_stem>_future_trial_loss_summary.csv`

### 5. Session overlap visualizations

Use this to visualize how tap behavior changes across study sessions. The
script writes cumulative SVGs: frame `01` shows session 1, frame `02` shows
sessions 1 + 2, and so on.

```sh
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir>
```

Example using a local exported file:

```sh
python3 scripts/session_overlap_visualization.py /Users/jimmy2/Downloads/keystrokes_cleaned_Tran_.csv --output-dir /Users/jimmy2/Downloads/session_overlap_Tran_review
```

Useful variants:

```sh
# Default review configuration: Jaccard grid 20 + prominent Gaussian overlap.
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir>

# Override the defaults if needed.
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir> --grid-size 20 --gaussian-step 3

# Synthetic sanity-check data.
python3 scripts/session_overlap_visualization.py --demo --output-dir /tmp/session-overlap-demo
```

Primary outputs:

- `session_jaccard_overlay_XX.svg`: direct grid-20 Jaccard view; grey cells are previous-only, colored cells are newest-only, and overlap cells are shared bins.
- `session_gaussian_overlap_XX.svg`: smooth Gaussian-overlap view; blue-grey is previous density, key color is newest density, and strongest key color is shared Gaussian density.
- `session_jaccard_summary.csv`: weighted Jaccard similarity/loss by cumulative session step.
- `session_jaccard_by_key.csv`: weighted Jaccard similarity/loss per key.
- `session_gaussian_overlap_summary.csv`: Gaussian-overlap similarity/loss by cumulative session step.
- `session_gaussian_overlap_by_key.csv`: Gaussian-overlap similarity/loss per key.
