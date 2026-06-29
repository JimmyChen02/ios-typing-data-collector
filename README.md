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
- holding-hand manifest CSV + captured images

### Holding-hand classification (HandyTrak)

The app can collect holding-hand data for offline classification following the
HandyTrak approach (Lim et al., UIST '21). After each typing session, a sheet
captures a front-camera upper-body photo and a self-reported holding-hand label
(Left / Right / Both / Unknown). The label defaults from the participant's
stated dominant hand but is always editable. Photo capture is optional —
label-only records are supported. Captured images are stored under
`Documents/hand_images/` and exported via the "Hand data" button in the summary
screen alongside a manifest CSV. See `scripts/README_hand.md` for the offline
training pipeline.

Open the app with:

```sh
open TypingResearch.xcodeproj
```

## Script Summary

- `scripts/clean_keystrokes.py`: adds normalized coordinates and outlier flags
- `scripts/keystrokes_to_pdf.py`: renders tap-distribution PDFs
- `scripts/gaussian_keyboard_pdf.py`: renders one full-dataset Gaussian boundary as PDF or SVG
- `scripts/session_overlap_visualization.py`: renders a baseline keyboard boundary plus cumulative per-session Gaussian boundaries and summary CSVs
- `scripts/key_session_boundary_video.py`: ranks per-key session-vs-ground-truth boundary overlap changes and exports one-key-at-a-time session frame sequences
- `scripts/plot_cleansing_subset.py`: renders a side-by-side raw-vs-cleaned keyboard view for a chosen session range
- `scripts/ground_truth_trial_loss.py`: compares trial prefixes against all-trial ground truth
- `scripts/numpy_analysis_utils.py`: shared histogram and CSV helpers for the analysis scripts
- `scripts/hand_dataset.py`: reads the holding-hand manifest CSV + images; returns (image_paths, labels) for the training pipeline
- `scripts/train_hand_classifier.py`: HandyTrak pipeline (preprocess → segment → classify) for holding-hand classification; heavy DL deps optional with lightweight fallbacks

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

- `session_gaussian_boundaries_00.svg`
- `session_gaussian_boundaries_00.pdf`
- `session_gaussian_boundaries_XX.svg`
- `session_gaussian_boundaries_XX.pdf`
- `session_gaussian_boundaries_all_sessions.pdf`
- `final_gaussian_ground_truth_boundary.svg`
- `final_gaussian_ground_truth_boundary.pdf`
- `session_gaussian_boundaries_summary.csv`
- `session_gaussian_boundaries_by_key.csv`

### 5. Run ground-truth trial loss

```sh
python3 scripts/ground_truth_trial_loss.py <cleaned_keystrokes.csv>
```

### 6. Export per-key boundary video frames

This is useful when you want to animate one key at a time over sessions, using the Gaussian boundary panel UI while also showing that key's Gaussian fade outside its winner boundary. Each exported frame now includes a `Session N   Trials X/Y` label, and the script also writes a combined whole-keyboard overview sequence plus an MP4 when PNG frames are enabled and `ffmpeg` is installed.

```sh
python3 scripts/key_session_boundary_video.py <cleaned_keystrokes.csv> --output-dir <output_dir>
```

Useful options:

```sh
python3 scripts/key_session_boundary_video.py <cleaned_keystrokes.csv> --output-dir <output_dir> --keys q space delete
python3 scripts/key_session_boundary_video.py <cleaned_keystrokes.csv> --output-dir <output_dir> --format both
python3 scripts/key_session_boundary_video.py <cleaned_keystrokes.csv> --output-dir <output_dir> --fps 3
python3 scripts/key_session_boundary_video.py <cleaned_keystrokes.csv> --output-dir <output_dir> --skip-letter-overview
python3 scripts/key_session_boundary_video.py --demo --output-dir /tmp/key-session-boundary-demo
```

Primary outputs:

- `key_boundary_overlap_summary.csv`
- `key_boundary_overlap_by_session.csv`
- `key_boundary_frame_manifest.csv`
- `largest_difference_key.txt`
- `frames/<key>/frame_XX_*.png`
- `frames/whole_keyboard/frame_XX_*.png`
- `videos/whole_keyboard_boundary.mp4`

**Implementation note — eval vs display coordinate systems:** The Gaussian model parameters (`mu_x`, `mu_y`, precision matrix) are fit in phone-pixel units that match the unscaled PDF key dimensions (~45 px/key). The script uses `--scale` (default 2.0) to enlarge the output image, but winner-map evaluation must stay in the scale=1.0 coordinate system. Evaluating in scaled coordinates inflates `dx` relative to `mu_x`/`mu_y`, causing fitted neighbour keys to score artificially low and letting fallback-Gaussian keys steal their territory. The script therefore always evaluates all winner maps and raster backgrounds using `base_panel_rect` / `base_frames` (scale=1.0) and only applies the display scale to the matplotlib axes, `imshow` extent, and key-outline rendering.

### 7. Generate a side-by-side cleansing check

```sh
python3 scripts/plot_cleansing_subset.py <raw_keystrokes.csv> <cleaned_keystrokes.csv> <output.pdf> --session-start 1 --session-end 5
python3 scripts/plot_cleansing_subset.py <raw_keystrokes.csv> <cleaned_keystrokes.csv> <output.pdf> --sessions 1 2 3 4 5
```
