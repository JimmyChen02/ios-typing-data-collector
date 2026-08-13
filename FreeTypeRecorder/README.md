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
5. **Complete the study:** 10 one-minute prompted sessions, Left ×3, Right ×3,
   Both ×4, in any order you choose. The home screen tracks progress (N/10) and
   which conditions remain.
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
