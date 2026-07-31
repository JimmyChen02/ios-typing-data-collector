# FreeTypeRecorder

An iOS app for typing-posture research. It runs a free-typing session while
recording the screen (with a keystroke overlay burned into the video), a
privacy-preserving front-camera silhouette, device motion (IMU), and every
keystroke — then backs it all up to Google Drive automatically.

## How to run

1. **Open & run.** `open FreeTypeRecorder.xcodeproj`, pick a real iPhone (the
   front camera doesn't exist in the Simulator), press Run.
2. **One-time setup.** The App Group must be configured — see
   [docs/SCREEN_BROADCAST_SETUP.md](docs/SCREEN_BROADCAST_SETUP.md). Skip if already done.
3. **Enter your name** on first launch.
4. **New Session → pick a hand:** Left, Right, or Both.
5. **Start recording:** tap the ● button → **FreeTypeRecorder** → **Start
   Broadcast**. Typing is recorded automatically.
6. **Finish:** tap **End Early** (top-right). Everything saves and uploads on its
   own; the screen closes when it's done.
7. **Where it goes:** Google Drive under `<your name>/<hand>/<session>/`.

## More docs

- Screen-recording / App Group setup: [docs/SCREEN_BROADCAST_SETUP.md](docs/SCREEN_BROADCAST_SETUP.md)
- Automatic Drive upload (researcher, one-time): [docs/AUTOMATIC_DRIVE_UPLOAD.md](docs/AUTOMATIC_DRIVE_UPLOAD.md)
- Google Drive backup details: [docs/GOOGLE_DRIVE_BACKUP.md](docs/GOOGLE_DRIVE_BACKUP.md)
