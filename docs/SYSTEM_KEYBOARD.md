# System-wide research keyboard (stage 3)

## Goal for this stage

Complete the English iPhone keyboard replica, excluding dictation and QuickPath:

1. Stock iOS chrome (gray/white keys, SF Symbol glyphs, suggestion bar, light/dark).
2. Character-preview popups and long-press accent/alternate menus.
3. Emoji page with categories and recents.
4. Landscape metrics, one-handed mode, space-bar trackpad.
5. Settings-parity toggles honored by the extension.
6. Every touch / suggestion / autocorrect / emoji event logged to the App Group.

A red recording dot is the only research marker. Suggestions and corrections
use a frozen, offline SymSpell English frequency model; Gaussian adaptation remains
deferred.

## Reality check

A third-party `UIInputViewController` cannot be a bit-perfect clone of Apple’s
keyboard. Apple’s layout assets, hit-test model, language model, dictation,
inline predictions inside the text field, and system text replacements are
private. This stage targets high visual/behavioral fidelity for English QWERTY
in portrait.

## iOS keyboard feature inventory

### Layout and chrome
- QWERTY letter layout; 123 / #+= symbol pages
- Shift / caps lock; auto-capitalization after `.?!` and at sentence start
- Delete with long-press repeat
- Space, Return (context label: return/go/search/send/…)
- Globe / next keyboard
- Emoji keyboard entry point
- Light / dark appearance matching system
- Portrait and landscape layouts; iPad floating / split / undocked
- One-handed mode (left/right shrink)

### Key interaction feedback
- Key popup / magnifier bubble on press
- Key highlight / press state
- Optional click sound and haptics
- Long-press accent / alternate character menus
- Long-press number/symbol alternates on letter keys

### Text intelligence
- Auto-Correction
- Predictive / QuickType suggestion bar
- Inline gray predictive completions in the text field (system-owned)
- Spell check underlines (host text system)
- Slide to Type / QuickPath
- Double-space → period
- Auto-capitalization / Caps Lock
- Shortcut / text replacement
- Contact name suggestions
- Multilingual typing / automatic language switching
- Dictation
- Undo autocorrect via backspace shortly after correction

### Editing helpers
- Space-bar trackpad mode
- Select / copy / paste / cut (host-owned)
- Undo / redo gestures (host-owned)

### Other
- Password / secure-field fallback to system keyboard
- External hardware keyboard support
- Accessibility (VoiceOver, Switch Control, …)
- Settings toggles for Auto-Capitalization, Auto-Correction, Predictive, etc.

### Implemented through stage 3
- Stock iOS-like visuals (light/dark), SF Symbol shift/delete/globe/emoji glyphs
- Shift key turns white when engaged; blue Return for go/search/send/done/…
- Character preview popup + press highlight + slide-to-neighbor
- Long-press accent and punctuation alternates with slide-to-select
- Momentary 123 / #+= gesture: hold the layout key, slide to a symbol, and
  release to insert it while returning to the original layout
- Emoji page: 8 categories + recents, ABC/globe/delete, delete repeat
- Landscape metrics (shorter rows, tighter gaps) and one-handed left/right mode
  with an expand handle; also reachable by holding the globe key
- Space-bar trackpad on long press with accumulated fine horizontal movement,
  hold-movement tolerance, and best-effort vertical line movement
- Accelerating delete repeat, escalating from characters to word deletion
- Smart punctuation (curly quotes, `--` → em dash), double-space → period
- Suggestion bar (SymSpell-backed local decoder, up to 3 candidates), autocorrect on
  space/return + undo via backspace
- Autocorrect covers confident substitutions, adjacent transpositions, and
  one-character insertion/deletion typos; sentence punctuation also commits it
- Pending autocorrect preview mirrors QuickType: quoted typed literal on the
  left, emphasized replacement pill in the center, and a third LM candidate
- Longer completions remain suggestions until explicitly tapped; pressing space
  commits the typed literal unless a qualifying typo autocorrection applies
- Temporary autocorrect correction chip in the suggestion bar with underlined
  replacement and tap-to-revert quoted original
- Settings parity: Auto-Capitalization, Auto-Correction, Predictive, Character
  Preview, Caps Lock, Smart Punctuation, One-Handed — set in the app, honored
  live by the extension
- Schema-v6 encrypted JSONL telemetry for keyboard touches, edits, predictions,
  emoji gestures, layout changes, latency, and environment snapshots

### Language-model baseline
- Source: official SymSpell `frequency_dictionary_en_82_765.txt`, pinned to
  commit `c239062ae02961df18ab7da1671d01b4388204e0`
- Source SHA-256:
  `c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b`
- Bundled model: the 30,000 highest-frequency unique English words from the
  official 82,765-word frequency dictionary, plus five frozen corrections for
  ambiguous common typos covered by regression tests
- The generator is `scripts/generate_symspell_english_model.py`; it verifies the
  source checksum before reproducing the bundled TSV.
- Scoring is deterministic and text-only. Touch proximity, user learning, and
  condition-specific personalization are excluded to avoid confounding classic
  versus Gaussian keyboard comparisons.
- The SymSpell frequency dictionary contains unigram frequencies but no
  contextual next-word n-grams. With an empty current word, the bar therefore
  shows the globally highest-frequency words rather than fabricated
  context rules.
- Candidate/autocorrect events record model identifier, source commit, source
  and artifact checksums, load status, candidate scores, and decode latency.

### Deferred / out of reach
- Dictation and QuickPath (explicitly out of scope)
- Emoji search field, skin-tone variant picker
- Apple's private language model, contextual next-word model, and host-app
  inline prediction styling in arbitrary apps
- Text replacement shortcuts, contact suggestions, multilingual auto-switching
- iPad floating / split / undocked layouts
- Adaptive Gaussian personalization
- Secure-field typing (iOS forces the system keyboard)

## Targets

- `TypingResearch`: containing app with keyboard-enablement instructions
- `AdaptiveKeyboard`: `UIInputViewController` extension
- `TypingResearchShared`: event schema, encrypted ledger, local decoder, preferences

App Group: `group.edu.cornell.ab3235.typingresearch`. Full Access is required
for shared research logging.

## Enable on a device

1. Install and launch TypingResearch.
2. Settings → General → Keyboard → Keyboards → Add New Keyboard → Adaptive Keyboard.
3. Enable Allow Full Access.
4. In any text field, switch to Adaptive Keyboard with the globe key.
5. Hold a letter to see the popup; type `teh` + space to see autocorrect.
6. Hold `e` for accents, hold space for the trackpad, hold the globe key for
   one-handed mode, tap the smiley key for emoji.

## Keyboard-extension telemetry (schema v6)

This telemetry is **not the study keystroke CSV**. The keyboard extension writes
one `KeyboardResearchEvent` per logical event to an encrypted append-only ledger;
the containing app can prepare a decrypted newline-delimited JSON (`.jsonl`)
export. The study CSV is produced by the timed study flow and has its own
participant/session/trial columns and cleaning pipeline. Do not feed keyboard
JSONL directly to the CSV cleaning scripts.

Every JSONL object carries `schemaVersion` (`6`), a unique event `id`,
monotonically increasing `sequenceNumber` within the extension process,
`timestamp`, extension-lifetime `sessionID`, event `kind`, and active `layout`
(`letters`, `numbers`, `symbols`, or `emoji`). Optional top-level link IDs
(`parentEventID`, `gestureID`, `editID`, `predictionOfferID`, `correctionID`)
join related touch, edit, prediction, and correction records. Event kinds are
`touch`, `insert`, `delete`, `candidateShown`, `suggestionAccepted`,
`autocorrectAccepted`, `autocorrectReverted`, `cursorMoved`, `layoutChanged`,
`externalMutation`, and `recordingChanged`; `inlinePredictionAccepted` is
retained only for decoding legacy schema-v5 records.

### Touches and gestures

`touchGesture` contains the complete sampled trajectory, not just the release
point:

- Gesture identity, initial/final targets, selected frame, start/end timestamps,
  duration, cancellation state, and whether the touch slid.
- Ordered `samples` for `began`, zero or more `moved`, and `ended`/`cancelled`.
  Each sample can include wall-clock and monotonic timestamps; absolute,
  precise-absolute, key-local, and normalized positions; radius and radius
  tolerance; force and maximum force; UIKit touch type; and target identifier,
  key, and frame.
- Legacy flat release-sample fields remain populated for compatibility:
  `touchX`, `touchY`, `preciseTouchX`, `preciseTouchY`, `touchRadius`,
  `touchRadiusTolerance`, `touchForce`, `touchMaximumForce`, `touchTimestamp`,
  `touchType`, and `keyFrame`.

Emoji collection selection uses direct touch sampling, but emoji action buttons
are driven by gesture recognizers. iOS does not expose the underlying
`UITouch` pressure/radius through those recognizers, so their trajectory samples
have positions and timing but `radius`, `radiusTolerance`, `force`,
`maximumForce`, and `touchType` are absent.

### Text edits and host context

Top-level `key`, `emittedText`, `rawContext`, `contextHash`, and `metadata`
provide the legacy/event summary. The structured `editOperation` records:

- `id`, operation `type` (`insert`, `delete`, `replace`, `cursorMove`, or
  `unknown`), `source` (`key`, `gesture`, `candidate`, `autocorrection`,
  `correctionReversion`, `smartPunctuation`, `emoji`, `external`, or `unknown`),
  and `trigger` (`touch`, `repeatDelete`, `candidateSelection`, `wordBoundary`,
  `textDidChange`, `programmatic`, or `unknown`).
- `contextBefore`, `contextAfter`, `originalText`, `replacementText`, and
  `deletedText`.
- `gestureID`, `parentEventID`, `predictionOfferID`, and `correctionID` links.

`externalMutation` means `textDidChange` observed a host-side context change; iOS
does not identify which host feature, app action, paste, hardware input, or
system behavior caused it, so its edit source remains `external` and operation
type may remain `unknown`. `UITextDocumentProxy` context before/after input can
also be `nil` or truncated at an iOS-controlled boundary. Consequently,
`rawContext`, hashes, before/after text, and environment context-presence flags
are best-effort observations, not a complete document history.

### Predictions, provenance, and latency

`predictionOffer` identifies an offer, records when it was shown, embeds ranked
`candidates`, identifies the literal candidate, and records model provenance.
Each candidate can contain `stableID`, `rank`, `text`, total `score`,
`languageScore`, and `isLiteral`. `predictionOutcome` links back by `offerID`
and records `previewShown`, `accepted`, `ignored`, `replaced`, or `reverted`,
plus selected-candidate and correction IDs and occurrence time. Legacy
top-level `candidates`, `selectedCandidate`, and `latencyMilliseconds` remain
for compatibility.

Prediction events also carry `modelProvenance`: model identifier, version,
artifact checksum, and pinned SymSpell source commit. The structured `latency`
separates touch duration, inter-event interval, text-proxy mutation time,
decoder time, whole-action time, and offer-to-selection time, all in
milliseconds.

### Environment and layout snapshots

Each event includes an `environment` snapshot when available: orientation,
one-handed mode, shift state, candidate-bar visibility, keyboard setting
toggles, hardware model, screen scale, OS/app versions, text-field traits,
whether before/after context is available, and recording state.

`layoutSnapshotID` links events to geometry. A full `layoutSnapshot` is emitted
only when the layout signature changes; later events reuse its ID. The snapshot
contains layout mode, keyboard and screen bounds, every rendered key identifier,
label, and frame, candidate-bar frame, and creation time.

### Storage, retention, and export controls

Recording is off until the participant explicitly enables **Allow recording and
automatic upload** in the containing app. This consent covers the full schema:
typed and surrounding context, inserted/deleted/replacement text, suggestions,
emoji, key labels, touch geometry, timing, and environment/settings data can all
be recorded and sent to the research server. The consent toggle must not replace
the study's approved consent process or IRB language.

After consent, recording can be paused under **Telemetry → Pause recording**.
**Encrypted events** shows the current decoded count, and the screen separately
shows pending and server-acknowledged counts plus the last successful upload.
**Prepare decrypted JSONL export** writes a protected temporary
`keyboard-events-<timestamp>.jsonl`, after which **Share prepared export** opens
the system share sheet. Preparing, sharing, or uploading does not delete the
encrypted source ledger.

On device, each event JSON object is independently AES-GCM encrypted and stored
as one base64 line in `research-events.aklog` in the App Group, using a
device-only key from the shared Keychain access group. Records are retained for
30 days by default and purged at most once per day when a new event is appended.
**Delete all keyboard logs** requires confirmation and permanently removes the
encrypted ledger; any previously prepared/shared decrypted export is a separate
file. It also does not delete records previously acknowledged by the server;
server deletion is a separate researcher action. Full Access is required for
extension/app shared logging and extension networking.

## Supabase automatic upload

The containing app and extension share `KeyboardEventUploader`. Uploads use a
random installation UUID and a Supabase anonymous-auth session held in the
shared Keychain; participants do not create a Supabase account. The public
project key ships in the app, while the service-role key exists only inside the
Edge Function environment.

The extension performs a lightweight due-check while the keyboard is active.
When at least 15 minutes have elapsed, it sends at most one 50-event batch. The
containing app retries when it launches or returns to the foreground. **Send
data now** in the Keyboard tab drains all pending batches immediately.

This is an activity-based schedule, not a guaranteed background timer. iOS does
not allow an inactive keyboard extension to wake every 15 minutes. If neither
the keyboard nor containing app is active, data remains encrypted on the device
and uploads on later activity. Network/server failures use bounded retry
backoff and never interrupt typing. Any legacy ledger event timestamped before
the current consent was granted remains local and is never uploaded.

The server acknowledges event UUIDs. The device records those acknowledgements
durably and resends unacknowledged events; the database's unique `event_id`
constraint makes retries idempotent. Local records keep the existing 30-day
retention policy. Acknowledgement metadata is pruned when its corresponding
ledger record is no longer present.

### Configure a build

1. Follow `supabase/README.md` to create the project, enable anonymous sign-ins,
   apply the migration, and deploy `ingest-keyboard-events`.
2. In the Debug and Release build settings for both `TypingResearch` and
   `AdaptiveKeyboard`, replace:
   - `SUPABASE_PROJECT_URL` with `https://<project-ref>.supabase.co`
   - `SUPABASE_PUBLISHABLE_KEY` with the project's publishable (or legacy anon)
     key
3. Never add `SUPABASE_SERVICE_ROLE_KEY` to either target.
4. Install a fresh build, open the Keyboard tab, review/accept consent, enable
   the keyboard with Full Access, generate test events, and use **Send data
   now**. Confirm the event UUIDs and receipt in the Supabase dashboard.

The free Supabase project is for prototype validation. Before real collection,
the PI must approve the provider/region, consent and IRB language, researcher
access, backup/retention/deletion policy, and production availability/cost.
