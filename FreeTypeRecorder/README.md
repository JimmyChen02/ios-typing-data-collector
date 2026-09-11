# FreeTypeRecorder

An iOS app for typing-posture research. It runs a free-typing session while
recording the screen (with a keystroke overlay burned into the video), a
privacy-preserving front-camera silhouette, device motion (IMU), and every
keystroke, then backs it all up to Google Drive automatically.

## How to run

1. **Open & run.** `open FreeTypeRecorder.xcodeproj`, pick a real iPhone (the
   front camera doesn't exist in the Simulator), press Run.
2. **One-time setup.** The App Group must be configured. See
   [docs/SCREEN_BROADCAST_SETUP.md](docs/SCREEN_BROADCAST_SETUP.md). Skip if already done.
3. **Enter your profile** on first launch: name, age, sex, dominant hand. All
   are required (phone model is detected automatically).
4. **Read the posture guide.** Sit upright, hold the phone with the hand shown,
   don't rest your arm on a desk. Shown once, re-openable from the menu.
5. **Complete the study:** 16 one-minute prompted sessions, Left ×3, Right ×3,
   Both ×10, in any order you choose. The home screen tracks progress (N/16) and
   which conditions remain. Existing progress is kept; a completed older
   3/3/4 study has six more both-hand sessions to finish.
6. **Each session:** tap **Start next session**, pick a hand, then tap the
   ● → **FreeTypeRecorder → Start Broadcast**. When recording starts, a popup
   reminds you which hand to use and to sit up. Type about the prompt for the
   full minute, then stop the broadcast to finish; everything saves and uploads
   automatically. Stopping before the minute is up discards the session and you
   redo it, so let the timer run out.
7. **Where it goes:** Google Drive under
   `<your name> - <phone>/<hand>/<name>,<trial>,<hand>/` (e.g.
   `Alex - iPhone 15 Pro/left/Alex,3,left/`), with `session_meta.json` carrying
   your demographics, phone type, session number, and prompt.

## More docs

- Test protocol + running the analysis on exported CSVs: [../TESTING.md](../TESTING.md)
- Screen-recording / App Group setup: [docs/SCREEN_BROADCAST_SETUP.md](docs/SCREEN_BROADCAST_SETUP.md)
- Automatic Drive upload (researcher, one-time): [docs/AUTOMATIC_DRIVE_UPLOAD.md](docs/AUTOMATIC_DRIVE_UPLOAD.md)
- Google Drive backup details: [docs/GOOGLE_DRIVE_BACKUP.md](docs/GOOGLE_DRIVE_BACKUP.md)

## Tap-coordinate collection

FreeTypeRecorder uses Apple's native keyboard, preserving its predictions and autocorrect.
An application-level touch observer records the native keyboard touches delivered
to FreeTypeRecorder during an active typing session. It forwards the original
events unchanged.

Tap-coordinate capture is automatic during recording; there is no keyboard-mode picker.

Each session saves and automatically backs up:

- `taps.csv`: one row per measured touch-down. Touches are recorded in the
  keyboard's screen rectangle, including its prediction bar. `tap_id` starts at 1 per session.
- `keystrokes.csv`: the original text-edit columns plus `keyboard_mode`, `tap_id`,
  and geometry columns retained for export compatibility. Native text callbacks
  are asynchronous, so edit rows leave `tap_id` and tap geometry blank. Use
  `taps.csv` for their measured positions; no nearest-time association is invented.
- `session_meta.json`: includes `keyboardMode=system`,
  `tapCaptureMethod`, and `measuredTapCount` filled at session stop.

`tap_x/y` are measured in **points relative to the keyboard's top-left corner**.
Native rows also contain `tap_screen_x/y` and `keyboard_screen_x/y`, all in screen
points. `tap_source=native_keyboard_region` identifies native observation, and
`touch_window` preserves the source window class as diagnostic evidence. Apple's
individual key labels, sizes, adaptive hit regions, and key-local coordinates are
unknown and remain blank.

The old custom-key geometry columns remain in the CSV schema as empty fields,
so existing export readers keep the same column layout. Older research-keyboard
sessions remain readable; new sessions always use Apple's keyboard.
`taps.csv` timestamps measure touch-down; keystroke timestamps measure the edit
callback. Both are relative to logger start.

Native rows describe touch-downs in the keyboard region, not inferred key presses;
a swipe has a starting touch-down, and a held delete may produce many edits from
one touch. Hardware input, paste, and
accessibility edits do not receive fabricated finger coordinates.

The isolated probe captured native coordinates in the simulator and on the
tested iPhone 17 Pro / iOS 26.6.1. The supplied phone CSV was verified: seven
keyboard-window touch-downs, six text changes, and distinct measured positions
inside the reported keyboard bounds. See [the hardware evidence](../experiments/AppleKeyboardProbe/README.md).
The integrated collector passed its simulator regression tests and built for
signed device installation. Its full
on-device recording flow still requires verification. A simulator-only click test
of the integrated editor and logger also saved eight measured native touches;
the nine text-edit callbacks replayed exactly to the final text. See
[the click-test exports](../experiments/AppleKeyboardProbe/evidence/integrated-simulator-ios18/README.md).
Event delivery may differ by OS/device: a header-only `taps.csv` and `measuredTapCount=0`
mean no touches were observed, not that the participant never tapped. Validate
each collection setup using [the protocol](../TESTING.md).
Intent/error classification is not implemented.
