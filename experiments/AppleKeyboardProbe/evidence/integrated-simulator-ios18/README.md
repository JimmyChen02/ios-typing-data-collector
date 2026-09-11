# Integrated FreeTypeRecorder simulator click test — 2026-09-11

Actual output from FreeTypeRecorder's production LoggingTextView, RecordingApplication / NativeKeyboardTouchCapture, and KeystrokeLogger. This is simulator mouse input, not participant data. Unlike EXAMPLE_native_taps.csv, these CSVs were written directly by the integrated logger without schema conversion.

Run: iPhone 16 Pro simulator, iOS 18.3.1, Debug build, --keyboard-click-test launch argument. The simulator-only screen skips camera, broadcast, IMU, and upload; it does not create study sessions or change study progress. test_meta.json records these exclusions.

Observed through direct CUA mouse clicks:
- Q, W, E at different positions: text Qwe, 3 taps.
- Backspace: Qw, 4 taps; E: Qwe, 5 taps.
- A click while predictions were updating produced a t edit: Qwet, 6 taps. This outcome is retained as observed; no key/intent attribution is asserted from it.
- Backspace: Qwe, 7 taps.
- Click the settled Apple prediction “question”: text "question ", 8 taps.
- Click inside the editor: count remained 8.
- Stop & Save: 8 tap rows and 9 edit rows, final text "question ".

Validated: contiguous tap IDs, finite and ordered timestamps, all touch positions within the reported keyboard bounds, keyboard-local coordinates equal screen position minus keyboard origin, native source window UIRemoteKeyboardWindow, unknown Apple per-key geometry left blank, no guessed native tap/edit IDs. Replaying all 9 text edit rows exactly reproduces final_text.txt.

First three recorded screen points: (15,605), (55,622), (105,608). Keyboard origin (0,538); local points (15,67), (55,84), (105,70). The last prediction-bar click was screen (204,563), local (204,25).

CUA accessibility activation inserted Q with zero touch events in an earlier diagnostic run; that is not a physical-click validation and is not included in these CSVs. CUA direct coordinate clicks initially failed with noWindowsAvailable. Restarting the macOS Simulator application (not merely rebooting simulated iOS) restored mouse input. Software keyboard was shown via Simulator I/O > Keyboard > Toggle Software Keyboard.

Screenshots from this run are saved locally in build/native-keyboard/click-test. The full physical-phone recording/broadcast/backup flow remains to be checked independently.
