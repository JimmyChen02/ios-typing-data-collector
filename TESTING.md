# Testing the substitution pipeline

For anyone recording a FreeTypeRecorder session and checking what the analysis
makes of it. Recording the app itself: see
[FreeTypeRecorder/README.md](FreeTypeRecorder/README.md).

## 1. What to do during your typing session

**Screen-record the whole session** (the app does this) — the video is the
ground truth your labels get checked against. Then, while typing naturally,
deliberately include each of these, ~5–10 times each:

| Behaviour | How | What it should label as |
|---|---|---|
| Autocorrect | type `teh`, hit space | autocorrect / spelling |
| Bar tap | type `tomo`, tap "tomorrow" in the bar above the keyboard (do some with each hand) | suggestion bar tap / completion |
| Inline prediction | type until grey ghost text appears after your cursor, accept it by hitting space | inline prediction — **most valuable, we have zero confirmed examples** |
| Bar-tap fix | type `teh`, tap "the" in the bar (don't hit space) | known blind spot — labels autocorrect; we want its timing data |
| Case fix | type lowercase `i`, hit space | autocorrect / capitalization |
| Contraction | type `its`, hit space → `it's` | autocorrect / contraction |
| Select + overtype | double-tap a word to select it, type a new word over it | manual overtype |
| Select + delete | double-tap a word, hit backspace | (behaviour count: whole-selection delete) |
| Revert a correction | let autocorrect change a word, then backspace it and retype **exactly** what you originally typed | outcome: reverted_to_original |
| Revert differently | let it correct, delete it, type a different word | outcome: replaced_with_other |
| Leave corrections alone | just keep typing after some corrections | outcome: kept |

Autocorrect must be ON in Settings → General → Keyboard. If a session is
deliberately run with it off, put `ac_off` in the session/file name (`ac_on`
otherwise) — the script warns when the name and the data disagree.

## 2. Running the analysis

Plain `python3`, no packages needed (stdlib only).

```sh
# download your session's keystrokes CSV from Drive into sessions_raw/
# as <session>_keystrokes.csv, then from the repo root:
python3 scripts/substitution_metrics.py sessions_raw/<session>_keystrokes.csv
```

Outputs land in `processed-keystrokes/`, named after your session (nothing
gets overwritten by other sessions):

- `<session>_processed.csv` — every keystroke row plus the labels
  (`substitution_source`, `substitution_effect`, `substitution_outcome`,
  `revert_latency_ms`, `next_delimiter_gap_ms`; column meanings in
  `.claude/data-dictionary.md`)
- `<session>_summary.md` — human-readable counts with definitions inline

Several sessions at once: `python3 scripts/substitution_metrics.py
sessions_raw/*_keystrokes.csv`. A combined machine-readable table:
add `--out combined.csv`.

Tests: `python3 -m pytest tests/test_substitution_metrics.py`

## 3. What to check / send back

1. The `## calibration` line of your `_summary.md`. Expected: `anchored` or
   `anchored_high`. **`global` or `global_conflict` on a session with plenty
   of corrections is a finding** — your device's timing doesn't fit the
   model; send the summary + processed CSV.
2. Compare the labelled rows against your screen recording — especially every
   bar tap and every inline prediction. Any mismatch: note the video
   timestamp and the row's `t_ms`.
3. If the script prints a `replay diverged` warning, that's not your mistake —
   iOS edited text without telling the logger. Note it and send the session.
4. Send back: the raw `_keystrokes.csv`, the screen recording, and your list
   of which behaviours you performed when.

## 4. Keyboard tap collection

FreeTypeRecorder always uses Apple's native keyboard. Coordinate capture starts
automatically with recording; there is no keyboard-mode picker.

First run a native Apple-keyboard session on the actual collection phone:

1. Type with clearly different contact positions within the same key; use Shift,
   predictions, backspace, and a swipe. Apple's usual keyboard behavior must remain.
2. Check that `taps.csv` has `keyboard_mode=system`,
   `tap_source=native_keyboard_region`, measured screen and keyboard-local points,
   and keyboard screen bounds. Verify local x/y equal screen x/y minus the
   keyboard's screen origin. Distinct contacts must preserve distinct positions.
3. Apple key labels, per-key geometry and normalization must remain blank.
   Native `keystrokes.csv` rows must not claim a tap ID. Prediction/autocorrect
   callbacks can be delayed or batched; they are not a verified tap-to-edit join.
4. Taps on the editor, setup controls, or after recording ends must not appear
   in the native keyboard stream. Reopen the keyboard and verify capture resumes.
5. The saved session and automatic Drive backup must include `taps.csv`.
   `session_meta.json` should have `keyboardMode=system`,
   `tapCaptureMethod=uiapplication_send_event`, and the matching `measuredTapCount`.
   If the count is zero despite typing, that device/build has not passed capture
   verification. Do not substitute key centers or treat zero as absence of taps.

`AppleKeyboardEditorTests.swift` verifies the native editor keeps UIKit's keyboard,
autocorrect, spell checking and predictions enabled.
`NativeKeyboardTapTests.swift` checks native geometry, missing key/association
fields, session boundaries, and event-observer window/editor gating. The probe's
direct-click simulator CSV is evidence for the mechanism, not a substitute for
checking the integrated recording/broadcast flow on a physical phone.

### Simulator mouse-click validation

Build and install the Debug FreeTypeRecorder app, then launch it with
`xcrun simctl launch booted jimmyx.freetyperecorder --keyboard-click-test`.
This simulator-only screen uses the production editor, application touch observer,
and CSV logger. Tap **Start**, focus the editor, click onscreen Apple keys, then
**Stop & Save**. If necessary, show the software keyboard from Simulator's
**I/O → Keyboard** menu. Use direct mouse clicks: accessibility activation may
insert text without generating a touch event.

Outputs go to the app's `Documents/SimulatorKeyboardClickTests/<UUID>/` folder.
`test_meta.json` marks simulator input and excludes camera, broadcast, IMU and
upload. This route does not create participant sessions or update study progress,
and it is compiled out of device and Release builds.

The 2026-09-11 direct-click run passed: 8 native keyboard-region touches, including
the prediction bar, and 9 text-edit callbacks that replay exactly to the final
text. Editor-area clicks did not increase the keyboard count. See the
[unmodified integrated exports](experiments/AppleKeyboardProbe/evidence/integrated-simulator-ios18/README.md).
