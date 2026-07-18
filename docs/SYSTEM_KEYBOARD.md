# System-wide research keyboard (stage 1)

## Goal for this stage

Ship a colorful iOS-style QWERTY keyboard extension that:

1. Looks unmistakably custom (per-letter colors).
2. Inserts text through `UITextDocumentProxy` like a normal keyboard.
3. Logs every touch / insert / delete (including raw text) to the App Group.
4. Shows typed text live in the TypingResearch app.

Calibration, Gaussian adaptation, warm-up, shadow mode, and autocorrect are
intentionally removed for this stage.

## Targets

- `TypingResearch`: containing app with a typing field, enablement steps,
  pause/export/delete for the event ledger.
- `AdaptiveKeyboard`: `UIInputViewController` extension.
- `TypingResearchShared`: event schema, encrypted ledger, preferences, App Group
  storage.

Both targets use the App Group `group.edu.cornell.ab3235.typingresearch`.
Typing works without Full Access; shared research logging requires Full Access.

## Enable on a device

1. Install and launch TypingResearch.
2. Open the Keyboard tab and follow the enablement steps (or open Settings).
3. Settings → General → Keyboard → Keyboards → Add New Keyboard → Adaptive Keyboard.
4. Enable Allow Full Access.
5. Tap the text field on the Keyboard tab, then use the globe key to switch to
   Adaptive Keyboard. Typed characters appear in that field as raw text.

iOS suppresses third-party keyboards in secure password fields.

## Logging

Recording is on by default for this stage and can be paused from the app.
Events include touch coordinates (precise + majorRadius + force), key frame,
layout mode, emitted text, document context, and latency. Events are AES-GCM
encrypted with a shared Keychain key and stored with
complete-until-first-authentication file protection. The app can export
decrypted JSONL or delete the ledger.

## What comes later

Later stages can reintroduce geometric priors, online Gaussian personalization,
consent toggles, and study assignment without changing the colorful keyboard
shell.
