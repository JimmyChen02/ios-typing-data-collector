# TypingResearch

TypingResearch has two parts:

- an iPhone app for running typing studies
- a `scripts/` folder for cleaning exports, rendering visuals, and running post-study analyses

## iOS App

The app runs timed iPhone typing sessions and records:

- touch coordinates and key geometry
- timing, correctness, and correction behavior
- session and study metadata

### Automatic trial and session outputs

The iOS app automatically turns collected trial data into these review outputs:

- session summaries with accuracy, WPM, and backspace behavior
- cleaned-data summaries with normalized tap positions and outlier flags
- tap-distribution keyboard views for raw and cleaned data
- per-session Gaussian boundary review pages showing how the boundary evolves over sessions
- a final Gaussian ground-truth boundary built from the full classic training data
- ground-truth loss charts showing how many trials are needed before the model stabilizes

In practice, this means the app gives you both the raw study data and the built-in review artifacts without needing to run Python scripts.

Keyboard modes:
- classic: normal fixed rectangular key regions
- gaussian: adaptive probabilistic key regions

Study designs:
- classic + adaptive: first half of sessions use the classic keyboard; second half use the Gaussian keyboard, using a model trained from the classic-session data
- classic only: every session uses the classic keyboard


Main in-app exports:

- raw keystroke CSV
- cleaned keystroke CSV
- tap-distribution PDF
- Gaussian boundary PDF
- ground-truth loss PDF

Open the app with:

```sh
open TypingResearch.xcodeproj
```

## Script Summary

- `scripts/clean_keystrokes.py`: adds normalized coordinates and outlier flags
- `scripts/keystrokes_to_pdf.py`: renders tap-distribution PDFs
- `scripts/gaussian_keyboard_pdf.py`: renders one full-dataset Gaussian boundary as PDF or SVG
- `scripts/session_overlap_visualization.py`: renders one Gaussian boundary per session plus summary CSVs
- `scripts/ground_truth_trial_loss.py`: compares trial prefixes against all-trial ground truth
- `scripts/future-trial-loss.py`: measures how early trials predict later trials
- `scripts/key_backoff_report.py`: shows which keys are fitted vs borrowed vs geometry fallback
- `scripts/loss-automation.py`: older overlap-analysis helper retained for compatibility

## Verification

Synthetic verification for the render and NumPy analysis pipeline:

```sh
bash scripts/verify_render_and_numpy_pipeline.sh /private/tmp/typing-research-verify
```

Synthetic/manual test helpers:

```sh
python3 scripts/manual_test_ground_truth_trial_loss.py --output-dir /tmp/ground-truth-loss-test
python3 scripts/manual_test_key_backoff_report.py --output-dir /tmp/key-backoff-test
```

## Offline Workflow

Run all commands from the repository root.

### 1. Clean an exported CSV

```sh
python3 scripts/clean_keystrokes.py <raw_keystrokes.csv>
python3 scripts/clean_keystrokes.py <raw_keystrokes.csv> <cleaned_keystrokes.csv>
```

If no output path is given, the script writes `<input_stem>_cleaned.csv`.

### 2. Render tap distributions

```sh
python3 scripts/keystrokes_to_pdf.py <cleaned_keystrokes.csv>
python3 scripts/keystrokes_to_pdf.py <cleaned_keystrokes.csv> <tap_distribution.pdf>
```

### 3. Render one overall Gaussian keyboard

```sh
python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv>
python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv> <gaussian_boundary.pdf>
python3 scripts/gaussian_keyboard_pdf.py <keystrokes.csv> <gaussian_boundary.svg>
```

### 4. Render per-session Gaussian boundaries

Default behavior writes both SVG and PDF outputs.

```sh
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir>
```

Example:

```sh
python3 scripts/session_overlap_visualization.py /Users/jimmy2/Downloads/keystrokes_cleaned_Tran_.csv --output-dir /Users/jimmy2/Downloads/session_boundary_Tran_review
```

Useful options:

```sh
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir> --format svg
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir> --format pdf
python3 scripts/session_overlap_visualization.py <cleaned_keystrokes.csv> --output-dir <output_dir> --raster-step 3
python3 scripts/session_overlap_visualization.py --demo --output-dir /tmp/session-boundary-demo
```

Primary outputs:

- `session_gaussian_boundaries_XX.svg`
- `session_gaussian_boundaries_XX.pdf`
- `session_gaussian_boundaries_all_sessions.pdf`
- `final_gaussian_ground_truth_boundary.svg`
- `final_gaussian_ground_truth_boundary.pdf`
- `session_gaussian_boundaries_summary.csv`
- `session_gaussian_boundaries_by_key.csv`

### 5. Run trial-loss analyses

Ground truth loss:

```sh
python3 scripts/ground_truth_trial_loss.py <cleaned_keystrokes.csv>
```

Future-trial loss:

```sh
python3 scripts/future-trial-loss.py <cleaned_keystrokes.csv>
```

Key backoff coverage:

```sh
python3 scripts/key_backoff_report.py <cleaned_keystrokes.csv>
```

Legacy overlap script:

```sh
python3 scripts/loss-automation.py <cleaned_keystrokes.csv>
```
