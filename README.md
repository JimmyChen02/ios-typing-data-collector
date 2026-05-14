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
