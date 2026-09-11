## 2026-09-11 — Left 3 / Right 3 / Both 10 implemented and verified

Final user instruction: retain the other hands; change only the both-hand quota
to 10. Study total now derives from quotas (16); existing hand picker remains.
Home rows display completed/required counts instead of a long row of dots.
Expanded PromptBank from 12 to 16 unique prompts. Existing persisted prompt order
and completed records are preserved, appending new prompts once. A completed old
3/3/4 study reopens at session 11 with six both-hand sessions remaining.

All 52 simulator tests passed, including the upgrade case and 16 distinct prompts.
Result bundle: /tmp/freetype-both-ten-tests.xcresult.
Signed generic iOS build succeeded; strict deep signature verification passed.
Updated build/native-keyboard/FreeTypeRecorder-native-keyboard.ipa; ZIP verified.
Simulator installed/launch confirmed. Used temporary launch-argument profile
SIMULATOR PREVIEW (no saved participant or recording) to inspect home: 0/16,
left 0/3, right 0/3, both 0/10. Hand picker showed all three options; selecting
Both showed Session 1 of 16 and Both hands. Returned home without starting
broadcast, camera capture, upload, or a study completion. Screenshot:
build/native-keyboard/study-quotas/left3-right3-both10.png.
Normal simulator recording still reports missing App Group as expected for the
unsigned simulator build; full signed-device workflow remains pending phone
availability. Apple's native keyboard/capture paths were not changed by this edit.
