# 2026-08-07 — Remove system keyboard extension

**Context:** `feature/systemwide-adaptive-keyboard`; retire the extension and
Supabase uploader without disturbing the replacement in-app research keyboard.

**Attempted:** Removed the extension target/product/build phases and signing
settings, deleted extension/backend/uploader files, removed uploader tests, and
kept the shared core, language-model source, and SymSpell resource in the app
and test setup.

**Errors:** None. A pre-existing build started before this refactor still showed
the old embedded extension, so validation used a fresh DerivedData directory.

**Fix / outcome:** `xcodebuild -scheme TypingResearch -destination
'generic/platform=iOS Simulator' -derivedDataPath
/tmp/TypingResearchNoExtensionDerivedData build` succeeded. The resulting build
graph had only `TypingResearch`; `xcodebuild -list` showed the app and test
targets, with no extension target. A subsequent `build-for-testing` with the
same destination and DerivedData also succeeded.

**Notes for next agent:** The encrypted-ledger implementation remains in
`AdaptiveKeyboardCore.swift` for compatibility, but `isRecording` is hard
disabled and no app source invokes the ledger. Existing camera concurrency and
legacy `onChange` warnings remain unrelated.
