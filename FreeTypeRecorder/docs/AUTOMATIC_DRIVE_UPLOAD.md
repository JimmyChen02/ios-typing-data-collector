# Automatic Drive upload for every participant (no per-device setup)

`FolderBackupService` (the local Files-picker folder) needs one manual tap
per device — fine for your own test phone, a hassle for every participant
who downloads the app. This is the zero-touch alternative: a small script
bound to *your* Google account uploads every session's video files (no
zip — each file individually) on every participant's behalf, with nothing
for them to sign into or configure.

You do this setup **once**, as the researcher. Participants do nothing.

## 1. Get your Drive folder's ID

Open **Mobile Keyboard Data** in Google Drive (in a browser is easiest).
The URL looks like:

```
https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz
```

Everything after `/folders/` is the folder ID — copy it.

## 2. Create the Apps Script project

1. Go to https://script.google.com and sign in with the same Google
   account that owns/has edit access to the Drive folder.
2. **New project**.
3. Delete the placeholder code and paste in the contents of
   `FreeTypeRecorder/apps_script/Code.gs` from this repo.
4. Replace the two placeholders at the top of the script:
   - `FOLDER_ID`: the folder ID from step 1.
   - `SHARED_TOKEN`: any random string you make up (e.g. mash the
     keyboard, or use a password generator) — this is just a shared
     secret so random internet traffic can't write into your folder if
     the URL ever leaks. It doesn't need to be memorable, just unique.
5. Rename the project (top left, next to the Apps Script logo) to
   something like "FreeTypeRecorder Upload".

## 3. Deploy it as a Web App

1. **Deploy > New deployment**.
2. Click the gear icon next to "Select type" and choose **Web app**.
3. Description: anything, e.g. "v1".
4. **Execute as: Me** (your account — this is what lets participants
   upload without their own Google sign-in).
5. **Who has access: Anyone**.
6. Click **Deploy**.
7. It will ask you to authorize the script's access to your Drive —
   click through the consent screens (you'll likely see an "unverified
   app" warning since this is your own personal script; click
   **Advanced > Go to [project name] (unsafe)** to proceed — this warning
   is Google being cautious about scripts in general, not a signal
   anything's wrong with this one, since it only runs code you just
   pasted in yourself).
8. Copy the **Web app URL** it gives you — it ends in `/exec`.

## 4. Plug both values into the app

Edit `FreeTypeRecorder/FreeTypeRecorder/Services/AppsScriptUploader.swift`
and replace:

```swift
private static let webAppURLString = "REPLACE_WITH_YOUR_DEPLOYED_WEB_APP_URL"
private static let sharedToken = "REPLACE_WITH_YOUR_SHARED_TOKEN"
```

with the URL from step 3.8 and the exact same token string you put in the
script in step 2.4. Rebuild the app (no need to re-run `xcodegen generate`
— this is just a source file change).

## What happens after that

On first launch, the app asks each participant for their name (once) and
remembers it. Every session after that, on every device, automatically
POSTs each file the session produced — one request per file, no zip —
tagged with the participant's name, this session's ID, and the file's
path relative to the session folder (`relativePath`, e.g.
`seg_images/0007.jpg`), to your Web App URL. Your script recreates that
same structure under **Mobile Keyboard Data/&lt;participant
name&gt;/&lt;session id&gt;/**, creating every subfolder the first time
it sees it:

```
Mobile Keyboard Data/
├── Alex Kim/
│   ├── 2026-07-28_143205/
│   │   ├── screen.mov              <- screen recording, tap dots + posture label
│   │   ├── face.mov                <- privacy silhouette video
│   │   ├── imu.csv                 <- 50Hz IMU stream for the session
│   │   ├── keystrokes.csv          <- every text-change event
│   │   └── seg_images/
│   │       ├── 0001.jpg            <- silhouette stills, ~every 3s
│   │       ├── 0002.jpg
│   │       ├── ...
│   │       └── manifest.csv        <- one row per still (see below)
│   └── 2026-07-28_150310/
│       └── ...
└── ...
```

No sign-in screen, no Files picker, nothing else for a participant to do
beyond entering their name once. The local Files-picker folder option is
still there in the app as an optional second path (useful mainly for your
own test device) and mirrors the same layout, but it's no longer required
for uploads to work.

## What's in each file

- **`imu.csv`** — same 50Hz column format as TypingResearch's
  MotionRecorder (`t_ms,attitude_roll,attitude_pitch,attitude_yaw,
  grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z`).
- **`keystrokes.csv`** — one row per text-change event
  (`t_ms,event_type,replacement_text,range_start,range_length,
  resulting_text_length,inter_key_interval_ms`); simpler than
  TypingResearch's InputEvent since free typing has no expected word to
  compare against.
- **`seg_images/manifest.csv`** — one row per still
  (`participant_name,session_id,frame_index,captured_at_iso,holding_hand,
  image_relative_path,imu_relative_path,image_pixel_width,
  image_pixel_height,camera_position,device_model,system_version,notes`),
  mirroring TypingResearch's hand-posture manifest columns closely enough
  to stay loadable by `scripts/hand_dataset.py`-style tooling with minor
  column-name adjustments. `holding_hand` is the live prediction from the
  same Core ML model TypingResearch uses (bundled into this app too),
  running on this session's own IMU stream.

## If you ever need to update the script

Editing `Code.gs` in the script editor alone doesn't update the live Web
App — you need **Deploy > Manage deployments > (pencil icon) > New
version > Deploy** so the `/exec` URL picks up the change. Do this now:
the script was updated again to accept a `relativePath` field (so nested
folders like `seg_images/` get recreated correctly) instead of a flat
`filename`.
