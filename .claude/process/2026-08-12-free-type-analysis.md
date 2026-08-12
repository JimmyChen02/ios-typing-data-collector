# 2026-08-12 — Audit of the typing-data pipeline: recording, cursor, substitution labels, Drive upload

## What was attempted
Read-only audit answering four questions: how typing data is recorded and reaches
Google Drive; whether the trial pipeline and the free-type pipeline differ; how
cursor movement is recorded versus taps, autocorrect, and QuickType suggestion
picks; and a fact-check of the claim that *"right now it just shows (both
autocorrected or replaced) as replaced."*

Verdict up front: **the claim is correct**, with two refinements — the label is
`replace` (not `replaced`), and some substitutions actually land in `paste`, not
`replace`. No code was changed.

## What was found

### 1. There are two pipelines, not one
The two apps in this repo are architecturally unrelated on the input side:

| | `TypingResearch/` (trial) | `FreeTypeRecorder/` (free type) |
|---|---|---|
| Keyboard | custom in-app SwiftUI keyboard | system iOS keyboard |
| Autocorrect / QuickType | impossible — no system keyboard | active, and the point of the study |
| Caret / cursor logging | none | `cursor.csv` |
| Reaches Drive | no — manual share sheet | yes, automatic on session finalize |

Any statement about autocorrect labelling applies **only to the free-type app**
(and to the Free Writing mode inside the trial app, below).

### 2. Trial-mode capture — only `insert` and `delete` are reachable
Trials never touch UIKit text input. `TrialView.swift:59-73` renders
`CustomKeyboardView` / `GaussianKeyboardView`; the sole capture primitive is a
per-keycap `DragGesture(minimumDistance: 0, coordinateSpace: .local)` at
`CustomKeyboardView.swift:291-308`, which emits a `TapInfo` carrying local tap
x/y plus key geometry.

Classification is a three-branch switch at `TrialView.swift:126-168`: `"delete"`
→ `.delete` (always `dropLast()`, `rangeLength = 1`); everything else → `.insert`
appended at `rangeStart = textBefore.count`. Text is a plain `@State var
typedText`, mutated only by `handleKeyTap`.

Consequences:
- `event_type` in trial exports can only ever be `insert` or `delete`. The
  `replace` and `paste` cases of `InputEventType` (`Models.swift:12-17`) are
  never emitted here.
- The strip above the keyboard (`TrialView.swift:57`, `172-178`) *looks* like the
  QuickType bar but is a dead-zone that forwards stray taps to the nearest
  top-row key — logged as an ordinary `.insert`, indistinguishable from a real
  key tap.
- There is no caret and no selection, so cursor movement is not merely unlogged,
  it does not exist. Typing is append-only, delete-from-end.

Export: `DataExporter.swift:46-61` writes `keystrokes.csv` /
`keystrokes_cleaned.csv` into `FileManager.temporaryDirectory`; handoff is the
share sheet at `SessionView.swift:818-823` (AirDrop / Save to Files).
`BackendClient.swift:12` is `isEnabled = false`.

`LoggingTextField.swift` is **not** used by trials — only by
`LivePostureDemoView.swift:119`. The one place in this app with a real system
keyboard is Free Writing (`FreeWritingTextView.swift:55-68`), which uses the same
shape-based heuristic described in §4 and has no
`textViewDidChangeSelection`, so caret moves are unlogged there too.

### 3. Free-type capture and per-session outputs
`Views/LoggingTextView.swift` (a `UITextView` representable) is the single origin
of both the keystroke log and the cursor log. Its delegate returns `true` and
observes rather than intercepting — the comment at `:108` records that returning
`false` and reassigning `text` bounced the caret to the end.

`SessionRecorder.swift:101-137` writes into
`Documents/Sessions/<hand>/<name>,<trial>,<hand>[_<HHmmss>]/`
(`SessionRecorder.swift:35-45`, names from `SessionNaming.swift:6-8`):

- `keystrokes.csv` — header at `KeystrokeLogger.swift:69`:
  `t_ms,event_type,replaced_text,replacement_text,range_start,range_length,resulting_text_length,inter_key_interval_ms`
- `cursor.csv` — header at `CursorSample.swift:34`:
  `t_ms,sel_start,sel_length,prev_sel_start,prev_sel_length,delta_chars,caret_x,caret_y,caret_h,touch_x,touch_y,touch_phase,tap_count,touch_age_ms,ms_since_last_text_change,text_length`
- `imu.csv` (`IMURecorder.swift:67`), `final_text.txt` (the replay checksum for
  `keystrokes.csv`), `session_meta.json` (`SessionMeta.swift:7-20`), `face.mov`,
  `screen.mov` (ReplayKit broadcast — the only artifact that captures the system
  keyboard), `seg_images/` + `manifest.csv`.

Both CSV loggers `start()` in the same tick (`SessionRecorder.swift:76-77`), so
`t_ms` shares one origin across `cursor.csv`, `keystrokes.csv`, and `imu.csv`.

### 4. Cursor movement vs. tap vs. autocorrect vs. suggestion pick

**Cursor.** Exactly one `cursor.csv` row per `textViewDidChangeSelection`
(`LoggingTextView.swift:115`). Taps and drags are not separate trigger paths —
the logger does not know *why* the caret moved, so it records **evidence** and
defers intent:

- caret geometry from `textView.caretRect(for:)` (`LoggingTextView.swift:122-133`),
  written empty rather than a fake `0.000` when non-finite or zero-height;
- the last in-app touch from `LastTouchTracker.shared.latest`
  (`LoggingTextView.swift:140-151`) — point converted window→text-view space,
  phase, tap count, age. Sourced in `TouchOverlayWindow.swift:36-53` inside
  `sendEvent`, gated on `RippleController.shared.isRecording`, and `reset()` at
  session start (`SessionRecorder.swift:80`) so a pre-session tap can't be
  mis-attributed;
- `ms_since_last_text_change`, a raw `Date?` differenced at read time
  (`LoggingTextView.swift:46-49`, `:99-101`, `:117`).

Intent is derived **offline** in `scripts/cursor_metrics.py:40-86` →
`typing` / `tap_reposition` / `double_tap_selection` / `drag` /
`keyboard_gesture` / `other`, using a `< 50 ms` text-change threshold
(`cursor_metrics.py:65`).

Two design details worth not re-litigating:
- The `programmatic` column was removed in `8591293c` because its only set-site
  sat inside `if uiView.text != text`, which never fires — the column was
  provably always `0`.
- Keyboard touches are invisible to the app (the system keyboard is a separate
  window). `LastTouchTracker.swift:11-14` treats that absence as *signal*: no
  recent touch **and** no text change ⇒ space-bar trackpad gesture.

**The substitution label — the fact-check.** `LoggingTextView.swift:58-84`:

```swift
if replacementText.isEmpty && range.length > 0 { eventType = .delete }
else if replacementText.count == 1 && range.length == 0 { eventType = .insert }
else if range.length > 0 { eventType = .replace }
else { eventType = .paste }
```

This is **shape-based, not intent-based**. Autocorrect, a QuickType suggestion
tap, smart punctuation, and sentence auto-capitalization all collapse into
`replace` — stated outright in the code comment at `:88-94`. Two refinements to
the original claim:

1. The enum case is `replace` (`KeystrokeEventType`, `KeystrokeLogger.swift:3-5`).
   `replaced_text` is the *column* holding the old string, not the label.
2. It is not only `replace`: a multi-character insert with `range.length == 0`
   is labeled `paste` even when nothing was pasted. A QuickType pick that appends
   a word at an empty caret lands there, not in `replace`.

**Why this cannot be fixed at capture time.** Autocorrect and a QuickType tap
arrive as byte-identical `textView(_:shouldChangeTextIn:replacementText:)` calls
with no distinguishing flag. `.claude/data-dictionary.md:142-148` records that the
*offered* candidates are also uncapturable (no API) and that ReplayKit hides the
system keyboard from `screen.mov` — only **accepted** substitutions are
observable at all. The intended disambiguation is offline heuristics, not richer
capture.

Pinned by `KeystrokeLoggerTests.swift:47-72`
(`test_replaceRecordsBothSidesOfTheSubstitution`, `"brwn"` → `"brown"`).

### 5. How data reaches Drive
Only `FreeTypeRecorder` uploads, and **not** via the Drive REST API — it POSTs to
a **Google Apps Script Web App** deployed under the researcher's own account:

- `AppsScriptUploader.swift:46` — one POST per file, base64 inside JSON, no zip.
  `:88-111` treats any non-`{ok:false}` response as success (documented
  workaround for the Apps Script 302 echo-URL); `:115-133` re-attaches POST
  method and body across that redirect.
- `apps_script/Code.gs:16-45` — `doPost` under a `LockService` script lock (avoids
  duplicate-folder races), writing to
  `Mobile Keyboard Data/<participant>/<hand>/<sessionId>/<relativePath>`.
- Auto-triggered on session finalize: `NotepadView.swift:334-341` →
  `SessionBackup.attempt`. Uploads are deliberately **serial**
  (`SessionBackup.swift:41`, rationale at `:13-20` — concurrent Apps Script
  executions race). Status persisted in `UploadStatusStore.swift:15,21`; per-session
  retry at `SessionListView.swift:217-228`.
- Optional second mirror to a Files-picker folder (`FolderBackupService.swift:35,48-90`);
  when both are configured, both must succeed (`SessionBackup.swift:83`).
- Drive folder name = `"<name> - <DeviceInfo.modelName>"` (`ParticipantStore.swift:53-57`).

**The Drive → laptop leg is manual.** Nothing in `scripts/` or any shell script
pulls from Drive; `scripts/merge_hand_export.sh:5-6` assumes an already-downloaded
zip in `~/Downloads`.

## Open issues found (none fixed in this run)
1. **`substitution_kind` is specced but unimplemented — this is the real gap.**
   `.claude/data-dictionary.md:131-140` defines `sentence_caps`,
   `smart_punctuation`, `autocorrect`, `quicktype_pick` as offline derivations for
   `event_type == "replace"`. Grep confirms zero implementation in Swift or
   Python. Until it exists, no analysis can separate autocorrect from a QuickType
   pick. The doc itself flags the rules as "starting rules... should be validated
   and refined against real data."
2. **Two column bugs in the trial exporter.** `DataExporter.swift:75` writes
   `event.studyId.uuidString` into the `session_id` column (the event's real
   `sessionId` is never exported); lines `:77` and `:79` *both* write
   `String(event.studySessionIndex + 1)`, so `trial_index` actually carries the
   session index, not `event.trialIndex`.
3. **Live credentials committed.** The shared token and deployed `/exec` URL are
   in source at `AppsScriptUploader.swift:24-25` and `Code.gs:13-14` — anyone with
   the repo can write into that Drive folder.
4. **Upload success is optimistic.** `AppsScriptUploader.swift:107-111` counts an
   unreadable response body as success, so `UploadStatusStore` green-checks can
   overstate what actually landed in Drive.
5. **Docs/code drift.** `AUTOMATIC_DRIVE_UPLOAD.md:59-65` still describes the URL
   and token as unreplaced placeholders, and both Drive docs describe a
   `<participant>/<session>/` path while code and `Code.gs:6` use
   `<participant>/<hand>/<session>/`.

## Outcome
Audit only — no source, config, or data was modified. The `replace` claim is
confirmed and now has a precise statement (§4) including the `paste` edge case and
the iOS-API reason it can't be resolved at capture time. Natural next step is
item 1: implement `substitution_kind` offline alongside `scripts/cursor_metrics.py`
and validate its rules against real free-type sessions.
