# TypingResearch

An iOS research app for studying adaptive mobile text entry. The project compares a fixed-layout keyboard against a personalized Gaussian keyboard that learns from touch coordinates, intended characters, and implicit correction feedback such as backspace.

## What The App Does

- Runs timed typing-study sessions on iPhone with two keyboard modes:
  - `classic`: fixed rectangular hit regions
  - `gaussian`: adaptive per-key probabilistic hit regions
- Captures per-keystroke touch coordinates, key geometry, timing, correctness, and correction behavior
- Presents a continuous text stream that expands as the participant types
- Starts the session timer on the first keypress instead of on screen load
- Exports raw and cleaned keystroke CSVs, plus raw, cleaned, and Gaussian visualization PDFs

## Current Study Design

The app is organized around a multi-session study:

- Sessions are split between `classic` and `gaussian` keyboard modes
- The current implementation uses the first half of the study as `classic` sessions and the second half as `gaussian` sessions
- During classic sessions, collected events are appended to the persistent Gaussian training corpus
- During gaussian sessions, the adaptive keyboard uses a frozen model fit from the earlier classic-session data

### Training logic

Each fitted key is represented by a 2D Gaussian over centered touch offsets. The current fitting pipeline:

- trains on the `intended` key when an `expectedChar` is available
- converts mistaps from the landed key's coordinate frame into the intended key's frame
- still allows deleted mistaps to train the intended key when an `expectedChar` is known
- includes delete taps as their own touch target
- falls back to accepted correct taps when intended-character supervision is unavailable, while excluding quickly deleted inserts from that fallback path

### Classification logic

At inference time, the Gaussian keyboard:

- evaluates each candidate key with Mahalanobis log-likelihood
- adds a soft spatial prior outside the key bounds
- uses anchor protection near key centers to avoid unstable boundary stealing
- chooses the winning key by a competitive argmax

### After the session

- per-key correctness and timing metrics
- session summaries
- CSV export
- backend export
- Gaussian corpus persistence

### Available exports

| Export | Contents |
|--------|----------|
| `Raw Keystrokes CSV` | One row per event with participant/session metadata, key geometry, timing, intended/actual/corrected characters |
| `Cleaned Keystrokes CSV` | Raw CSV plus outlier distance/flag columns from `KeystrokeCleaner` |
| `Raw PDF` | Keyboard dot plot using raw events |
| `Cleaned PDF` | Keyboard dot plot after applying keystroke cleaning |
| `Gaussian PDF` | Adaptive keyboard territory map + Gaussian ellipses + historical taps from the persisted Gaussian corpus |

## Offline Analysis Scripts

The `scripts/` folder contains matching analysis utilities:

- `scripts/gaussian_keyboard_pdf.py`: mirrors the current intended-key Gaussian fitting logic and exports a Gaussian keyboard PDF from a keystroke CSV
- `scripts/clean_keystrokes.py`: flags spatial / timing outliers in exported keystroke CSVs
- `scripts/ground_truth_trial_loss.py`: builds an all-trials ground truth, then exports graph-ready loss CSVs for the prefix path (`{1}`, `{1,2}`, ...) and averaged all-combinations trial subsets
- `scripts/keystrokes_to_pdf.py`: renders raw/overlay keyboard dot plots from CSV

Example:

```sh
python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv> [output.pdf]
```

Ground-truth loss examples:

```sh
python3 scripts/ground_truth_trial_loss.py <cleaned_keystrokes.csv>
python3 scripts/manual_test_ground_truth_trial_loss.py --output-dir /tmp/ground-truth-loss-test
```

### To open the app:
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
python3 scripts/session_overlap_visualization.py /Users/jimmy2/Downloads/keystrokes_cleaned_Tran_.csv --output-dir /Users/jimmy2/Downloads/session_overlap_Tran --territory-step 4
```

Useful variants:

```sh
# Bigger, less strict Jaccard bins.
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir> --grid-size 20

# Smoother Gaussian/territory sampling. Smaller step means larger SVG files.
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir> --territory-step 3

# Synthetic sanity-check data.
python3 scripts/session_overlap_visualization.py --demo --output-dir /tmp/session-overlap-demo
```

Primary outputs:

- `session_overlap_overlay_XX.svg`: cumulative Gaussian territory view with newest-session dots colored and previous dots grey.
- `session_jaccard_overlay_XX.svg`: direct binned Jaccard view; grey cells are previous-only, colored cells are newest-only, and overlap cells are shared bins.
- `session_gaussian_overlap_XX.svg`: smooth Gaussian-overlap view; blue-grey is previous density, key color is newest density, and strongest key color is shared Gaussian density.
- `session_overlap_summary.csv`: weighted Jaccard similarity/loss by cumulative session step.
- `session_overlap_by_key.csv`: weighted Jaccard similarity/loss per key.
- `session_gaussian_overlap_summary.csv`: Gaussian-overlap similarity/loss by cumulative session step.
- `session_gaussian_overlap_by_key.csv`: Gaussian-overlap similarity/loss per key.
