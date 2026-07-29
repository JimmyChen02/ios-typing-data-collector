# Data Dictionary — Study CSV and Keyboard JSONL

This repository has two distinct telemetry formats:

1. **Study keystroke CSV** — produced by the timed study app. Raw columns are
   written by `DataExporter`; cleaning columns are appended by
   `scripts/clean_keystrokes.py` (rows are never deleted, only flagged).
2. **System-keyboard JSONL** — produced by the `AdaptiveKeyboard` extension.
   Each line in a prepared export is one schema-v6 `KeyboardResearchEvent`.

The JSONL is not a new version of the CSV and is not input to
`scripts/clean_keystrokes.py`. Its extension `sessionID` is not the study CSV
`session_id`, and it has no participant, trial, expected-character, correctness,
or cleaning columns.

## System-keyboard encrypted JSONL (schema v6)

The on-device source is `research-events.aklog`: one independently AES-GCM
encrypted JSON payload per base64 line. The encryption key is device-only and
stored in the shared Keychain access group. The containing app's **Prepare
decrypted JSONL export** control decrypts valid records into
`keyboard-events-<timestamp>.jsonl`; **Share prepared export** exposes that
temporary file through the system share sheet. Export does not clear the source.
Recording is on by default, **Pause recording** stops new appends, **Encrypted
events** and **Refresh event count** expose the current count, and **Delete all
keyboard logs** permanently removes the encrypted ledger after confirmation.
Retention is 30 days by default, with a purge checked at most daily when an event
is appended.

All properties below are JSON keys. Swift optionals may be absent or `null`.
Dates are ISO-8601 strings, UUIDs are strings, coordinates and dimensions are
UIKit points unless stated otherwise, and latency/duration values are
milliseconds.

### Event envelope and links

- `schemaVersion` (int): always `6` for newly recorded events.
- `id` (UUID): unique event ID.
- `sequenceNumber` (uint64?): monotonically increases within the current
  keyboard-extension process.
- `timestamp` (date): event wall-clock time.
- `sessionID` (UUID): extension-lifetime session ID; not a study session ID.
- `kind` (enum): `touch`, `insert`, `delete`, `candidateShown`,
  `suggestionAccepted`, `autocorrectAccepted`, `autocorrectReverted`,
  `cursorMoved`, `layoutChanged`, `externalMutation`, or `recordingChanged`.
  `inlinePredictionAccepted` is retained only to decode schema-v5 data.
- `layout` (enum): `letters`, `numbers`, `symbols`, or `emoji`.
- `parentEventID`, `gestureID`, `editID`, `predictionOfferID`, `correctionID`
  (UUID?): top-level relationship IDs used to join event, gesture, structured
  edit, prediction offer/outcome, and correction records.
- `metadata` (object of string:string): kind-specific compatibility/debug
  details.

### Touch trajectory

`touchGesture` is the canonical complete gesture:

- `id` (UUID), `startedAt`/`endedAt` (date?), `durationMilliseconds` (double?),
  `wasCancelled` (bool), and `didSlide` (bool).
- `initialTarget`/`finalTarget` (`TouchTarget`?), and `selectedFrame` (rect?).
- `samples` (ordered `TouchSample[]`): began, moved, and ended/cancelled samples.

Each `TouchSample` has:

- `phase`: `began`, `moved`, `ended`, or `cancelled`.
- `wallTimestamp` (date?) and `monotonicTimestamp` (double seconds?).
- `absolutePosition`, `preciseAbsolutePosition`, `localPosition`, and
  `normalizedPosition` (`{x,y}`?). Normalized coordinates are relative to the
  sample's target frame.
- `radius`, `radiusTolerance`, `force`, `maximumForce` (double?) and `touchType`
  (UIKit raw int?).
- `target` (`TouchTarget`?): `identifier`, optional logical `key`, and optional
  `frame` (`{x,y,width,height}`).

Legacy flat touch fields summarize the final/release sample and remain for
compatibility: `touchX`, `touchY`, `preciseTouchX`, `preciseTouchY`,
`touchRadius`, `touchRadiusTolerance`, `touchForce`, `touchMaximumForce`,
`touchTimestamp`, `touchType`, and `keyFrame`. `key`, `emittedText`,
`rawContext`, and `contextHash` are also legacy/event-level summaries.

iOS limitation: emoji collection-cell selection has direct touch samples, but
emoji action buttons use gesture recognizers that do not expose the underlying
`UITouch`; those samples lack pressure/radius (`radius`, `radiusTolerance`,
`force`, `maximumForce`) and `touchType`.

### Structured edits

`editOperation` contains:

- `id` (UUID) and `type`: `insert`, `delete`, `replace`, `cursorMove`, or
  `unknown`.
- `source`: `key`, `gesture`, `candidate`, `autocorrection`,
  `correctionReversion`, `smartPunctuation`, `emoji`, `external`, or `unknown`.
- `trigger`: `touch`, `repeatDelete`, `candidateSelection`, `wordBoundary`,
  `textDidChange`, `programmatic`, or `unknown`.
- `contextBefore`, `contextAfter`, `originalText`, `replacementText`, and
  `deletedText` (string?).
- `gestureID`, `parentEventID`, `predictionOfferID`, and `correctionID` (UUID?).

The event-level `parentEventID` can be absent, while an edit's `parentEventID`
links back to its enclosing event. IDs should be used instead of temporal
adjacency when reconstructing prediction/correction chains.

An `externalMutation` is only a difference observed during `textDidChange`.
iOS does not reveal the true external source, so `source` remains `external`,
`trigger` is `textDidChange`, and `type` may be `unknown`. Host
`documentContextBeforeInput`/`documentContextAfterInput` can be `nil` or
truncated by iOS. Therefore `rawContext`, `contextHash`, edit before/after text,
and the environment's context-presence booleans are best-effort and must not be
treated as a complete host-document audit trail.

### Prediction offers, outcomes, and model

`predictionOffer` contains:

- `id` (UUID), `offeredAt` (date?), and `literalCandidateID` (string?).
- `candidates` (`DecoderCandidate[]`), each with `stableID` (string?), `rank`
  (int?), `text`, `score`, `languageScore`, and `isLiteral`.
- `model` (`ModelProvenance`?): `identifier`, `version`, `artifact`, and
  `sourceCommit`.

`predictionOutcome` contains `offerID`, `kind` (`previewShown`, `accepted`,
`ignored`, `replaced`, or `reverted`), optional `selectedCandidateID`,
`correctionID`, and `occurredAt`. The enclosing event repeats relevant offer and
correction IDs. Prediction-related events can also include top-level
`modelProvenance` with the frozen SymSpell model identifier, dictionary version,
artifact checksum, and pinned source commit.

Legacy top-level `candidates`, `selectedCandidate`, and `latencyMilliseconds`
remain for compatibility.

### Granular latency

`latency` (`KeyboardLatency`?) separates:

- `touchDurationMilliseconds`
- `interEventMilliseconds`
- `proxyMutationMilliseconds`
- `decoderMilliseconds`
- `actionTotalMilliseconds`
- `offerToSelectionMilliseconds`

Values are optional because not every event performs every stage.

### Environment and layout snapshots

`environment` (`KeyboardEnvironmentSnapshot`?) contains:

- `orientation`, `oneHandedMode`, `shiftState`, and `candidateBarVisible`.
- `settings`: `autoCapitalizationEnabled`, `autocorrectionEnabled`,
  `predictiveEnabled`, `characterPreviewEnabled`, `capsLockEnabled`, and
  `smartPunctuationEnabled`.
- `deviceModel`, `screenScale`, `operatingSystemVersion`, and `appVersion`.
- `fieldTraits`: raw UIKit `keyboardType`, `returnKeyType`,
  `autocapitalizationType`, `autocorrectionType`, `spellCheckingType`,
  `enablesReturnKeyAutomatically`, and `isSecureTextEntry`.
- `hasContextBefore`, `hasContextAfter`, and `isRecording`.

`layoutSnapshotID` identifies the geometry in effect. `layoutSnapshot` is
included only when the rendered layout signature changes; subsequent events
reuse the ID. A snapshot has `id`, `layout`, `keyboardBounds`, optional
`screenBounds`, `keyGeometries` (each key's `identifier`, optional `label`, and
`frame`), optional `candidateBarFrame`, and `createdAt`.

## Study keystroke CSV

## Raw columns (iOS export)
| Column | Type | Meaning |
|---|---|---|
| `participant_first`, `participant_last` | str | Participant name |
| `session_id` | str | Unique session identifier |
| `session_mode` | str | `classic` or `gaussian` |
| `study_session_index` | int | Order of this session within the study design |
| `trial_id` | str | Unique trial identifier |
| `trial_index` | int | Trial number within the session (0–14; 15 trials/session) |
| `event_type` | str | `insert` / `delete` (backspace) |
| `key_label` | str | Key that was hit (a–z, `space`, `delete`) |
| `tap_local_x`, `tap_local_y` | float | Tap position in the hit key's local frame (points) |
| `tap_norm_x`, `tap_norm_y` | float | App-side normalized tap (local / key size) |
| `key_width`, `key_height` | float | Hit key geometry (points) |
| `key_row`, `key_col` | int | Hit key grid position |
| `expected_char` | str | Character the prompt expected here |
| `actual_char` | str | Character actually produced |
| `corrected_char` | str | Char after any correction |
| `is_correct` | int | 1 if actual == expected |
| `previous_key_label` | str | Prior key (for IKI context) |
| `text_before` | str | Field text before this event (empty = trial start) |
| `timestamp_ms` | int | Event time (ms) |
| `inter_key_interval_ms` | float | ms since previous event |

## Cleaning columns (appended by clean_keystrokes.py)
| Column | Type | Meaning |
|---|---|---|
| `tap_norm_x`, `tap_norm_y` | float | **Recomputed** normalized tap (tapLocal / keySize); 0=left/top, 1=right/bottom. Note: appears a second time after the raw pair. |
| `dist_from_target_kw` | float | Distance from tap to the **expected** key rect, in key-widths (0 if inside) |
| `is_outlier` | int | 1 if any flag fired |
| `outlier_flags` | str | Pipe-separated reasons (empty = clean) |
| `is_spatial_outlier` | int | (some variants) 1 if normalized tap outside `[-0.5, 1.5]` |

## Outlier flag values
| Flag | Trigger |
|---|---|
| `spatial` | `tap_norm_x/y` outside `[-0.5, 1.5]` (>½ key-width outside hit key) |
| `far_from_target` | `dist_from_target_kw` > 1.25 (too far to be a neighbor mistap) |
| `iki_low` | `inter_key_interval_ms` < 50 (double-registration) |
| `iki_high` | `inter_key_interval_ms` > 3000 (pause / distraction) |
| `trial_start` | `text_before` == "" (first keystroke of a trial) |
| `delete_event` | `event_type` == "delete" (intentional backspace) |
| `sigma_outlier` | > N std devs from expected key's cluster mean (only with `-s`) |

Filename convention: `<name>_cleaned_t<thr>[_s<sigma>].csv` encodes the cleaning
thresholds used (e.g. `_cleaned_t1.0_s2.5.csv`).
