# Screen recording that includes the keyboard (Broadcast Extension)

The app's original screen recording used `RPScreenRecorder.startCapture`
(in-app capture), which iOS deliberately strips the system keyboard out
of — so the keyboard, its key-press popups, and the autofill/QuickType bar
never appeared in `screen.mov`. That's an OS privacy restriction with no
API override.

The fix is a **Broadcast Upload Extension**: a second, tiny app target
that receives the *entire* composited display (keyboard and all), because
broadcast capture grabs the real framebuffer. This is the same mechanism
Zoom/Teams use to screen-share your keyboard.

## One-time setup you must do (I can't do these for you)

### 1. Register the App Group

The extension runs in its own process and can't see the app's Documents
folder, so it hands the recording over through a shared **App Group**
container. Both targets already declare the entitlement in `project.yml`
(`group.jimmyx.freetyperecorder`), but the group itself must exist in your
Apple Developer account:

- Easiest path: open the project in Xcode, select the **FreeTypeRecorder**
  target → **Signing & Capabilities** → confirm **App Groups** lists
  `group.jimmyx.freetyperecorder` with a checkmark (Xcode's automatic
  signing will offer to register it if it doesn't exist). Repeat for the
  **BroadcastExtension** target — it must have the **same** group checked.
- If automatic signing doesn't offer it: https://developer.apple.com →
  Certificates, Identifiers & Profiles → Identifiers → App Groups → **+**
  → create `group.jimmyx.freetyperecorder`, then enable it on both the
  `jimmyx.freetyperecorder` and `jimmyx.freetyperecorder.broadcast` App IDs.

If the group ID is ever changed, update `BroadcastShared.appGroupID`
(in `Shared/BroadcastShared.swift`) and both entitlements in `project.yml`
to match, then `xcodegen generate`.

### 2. Build & install

Build the **FreeTypeRecorder** scheme onto your device as usual — Xcode
embeds the extension inside the app automatically (no separate install).

## How a session works

The broadcast drives the whole session — there's no separate Start/Stop
for the app's own recorders.

1. Open a new session. At the top: **Step 1: tap ● → FreeTypeRecorder →
   Start Broadcast**.
2. Tap the **●** button → system sheet → choose **FreeTypeRecorder** →
   **Start Broadcast** → 3-second countdown. The status-bar clock turns
   red and the **session auto-starts** (face video, IMU, keystrokes,
   seg-images all begin).
3. Type for the full minute (the countdown starts on your first keystroke).
4. When the minute is up, stop the broadcast from the **red clock in the
   status bar → Stop**. Stopping *before* the minute is up discards the
   session — the app tells you it was too short and you run it again.
5. The app shows **"Saving…"** (exit is locked here), collects the video
   into the session folder as `screen.mov`, backs everything up, and
   **closes automatically**.

The video's real bytes are written to the extension's own temp directory
(AVAssetWriter fails writing straight into the App Group container), then
copied into the shared container on finish for the app to collect.

If the broadcast is never started, the session can't run — the app is
broadcast-driven. (A 30-second safety timeout during "Saving…" prevents
any hang if the finished video never lands.)

## Why the taps are required

iOS does not let any app silently start a full-screen broadcast — the
"Start Broadcast" sheet is a mandatory OS step, the same as any
screen-sharing app. There's no way around it; it's the price of capturing
the real keyboard in the video.

## Note on the simulator

The broadcast picker and full-screen capture only work on a physical
device. In the simulator the picker button appears but starting a
broadcast does nothing useful — test this feature on real hardware.
