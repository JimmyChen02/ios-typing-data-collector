# Automatic Google Drive backup

No Google Cloud project, OAuth client, or API key needed. FreeTypeRecorder
uses iOS's own Files picker to remember a destination folder, which can be
a folder inside Google Drive if the Drive app exposes itself there.

## One-time setup, on your iPhone

1. Install the **Google Drive** app and sign into your account, if you
   haven't already.
2. In Google Drive (the web app or the mobile app), create a folder named
   exactly **`Mobile Keyboard Data`** at the top level of your Drive, if it
   doesn't already exist — this is the folder every session will back up
   into. (You can also create it directly from step 4's picker via
   "New Folder", if that's easier.)
3. In the Google Drive app: check **Settings** to make sure it's enabled
   to show up in the **Files** app — on by default in current versions,
   but worth checking if it doesn't appear as a location in step 4.
4. Open **FreeTypeRecorder**, and on the session list tap
   **Choose "Mobile Keyboard Data" Folder**.
5. In the picker that appears, tap **Browse** (bottom tab) if needed, find
   **Google Drive** under Locations, navigate to the **Mobile Keyboard
   Data** folder, and tap it to select it (a single tap on the folder
   itself, not into it).

That's it — no sign-in screen inside FreeTypeRecorder itself, since the
picker is just handing the app permission to write into that one folder.

## How files are stored

One subfolder per participant (named from what they entered on the app's
welcome screen), then one subfolder per session, with every file the
session produced directly inside (and its own `seg_images/` subfolder) —
no zip:

```
Mobile Keyboard Data/                       <- the folder you picked
├── Alex Kim/
│   ├── 2026-07-28_143205/                  <- one session
│   │   ├── screen.mov
│   │   ├── face.mov
│   │   ├── imu.csv
│   │   ├── keystrokes.csv
│   │   └── seg_images/
│   │       ├── 0001.jpg
│   │       ├── ...
│   │       └── manifest.csv
│   └── 2026-07-28_150310/
│       └── ...
└── ...
```

`screen.mov` is the screen recording with tap dots and the live
holding-hand prediction burned into the top-right corner; `face.mov` is a
privacy-preserving silhouette video (never the real camera image);
`imu.csv`/`keystrokes.csv` are the raw sensor/typing logs for the
session; `seg_images/` holds periodic silhouette stills + a manifest CSV
for offline CNN training. Every new session adds one more timestamped
subfolder under that participant's folder.

## What happens after each session

The app automatically copies every one of those files into that
session's subfolder right after you stop recording — no further taps.
The session list shows a green cloud-check once everything has landed
there.

If the copy fails for any reason (folder permission revoked, Drive app
signed out, etc.), the session list still shows:
- A retry button (cloud-up icon) to try the automatic copy again
- A **Save/Share** button that opens the normal iOS share sheet for every
  file the session produced (both videos, both CSVs, and every seg-image
  still), so you can always save them manually (to Drive, Files, AirDrop,
  Mail, etc.) as a fallback
