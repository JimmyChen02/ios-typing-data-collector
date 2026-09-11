# FreeTypeRecorder research keyboard tap collection

User requested the TypingResearch coordinate-capture approach in FreeTypeRecorder.
Intent collection is explicitly deferred. Added a UIKit inputView adapting the
classic QWERTY geometry (5pt sides, 6pt gaps, staggered rows), with touch-down
callbacks similar to the Gaussian keyboard overlay. Home screen defaults to
Research keyboard; Apple keyboard remains a selectable separate condition.

KeystrokeLogger records all research-key taps in taps.csv and links text edits
with tap_id; measured keyboard-local, key-local, normalized coordinates and key
geometry are appended to keystrokes.csv. Controls/empty backspaces have taps but
no edits. Hardware/paste/accessibility edits have empty coordinates. Session
metadata includes keyboardMode. Existing recursive backup includes taps.csv.

Validation: build succeeded; 54 iOS 26.1 simulator tests and 71 Python analysis
tests passed. Hosted SwiftUI test initially failed because the UIHostingController
was not in a window; mounting a UIWindow and yielding the first render fixed the
test harness. Result bundle /tmp/freetype-tap-verified.xcresult. On-device testing
of physical touch input plus full camera/broadcast/backup remains necessary.

## Native-keyboard investigation (user: FIND A WAY)

Created isolated experiments/AppleKeyboardProbe, iOS 15+, public UIApplication
subclass forwarding sendEvent unchanged. Native UITextView uses default keyboard
and traits. CSV logs touches and text changes separately, screen points and
keyboard rectangle, never inferred key centers. Found positive direct Simulator
UI click result on iOS 18.3.1: UIRemoteKeyboardWindow touch coordinates 19/59/99,
y610; Q/Qw/Qwe text changes, native prediction bar and later Wee autocorrection.
Saved evidence/simulator-ios18-direct-clicks.csv. Modern simulator behavior must
not be generalized to physical devices. Prior categorical no-raw-touches answer
was too broad; actual hardware result is needed.

XCUITest synthesized key-element taps failed to insert text on both 26.1 and
18.3.1 (first also had hidden software keyboard), so these are inconclusive.
Direct CUA UI clicks worked. Probe built and signed for connected iPhone17Pro,
iOS26.6.1; installed bundle jimmyx.applekeyboardprobe. Launch blocked by generic
signing/entitlement/trust error. Local strict codesign verification passed,
profile includes device and matches bundle, expires2026-09-18. Asked user to
open probe, Start, Check once, type qwe and report In keyboard. Device trust may
need review under General > VPN & Device Management per Apple personal-team docs.

No main-app native capture implementation yet; no intent changes. README has
routes/evidence/limitations and exact hardware-check steps. No jailbreak or
private API modifications applied. SensorKit no raw x/y; SRD security-research
scope; older iOS15/16 public observer plausible untested; compatible instrumented
research hardware remains a separate possible route.

## Native integration after user reports phone count 3

User replied "says 3" to the physical-probe In keyboard question, then instructed
"keep finishing". Added production UIApplication subclass/entry point calling
NativeKeyboardTouchCapture before forwarding every original event. Observer binds
only the native LoggingTextView, requires active editable first responder and
system-mode logger session, matches screen, excludes editor-window touches, and
validates native points inside the keyboard frame. Keyboard UI/traits/predictions
remain native. Session stop writes taps.csv and measuredTapCount/capture method
metadata. Native rows have screen+keyboard points, frame origin/size and source
window; all individual Apple key geometry and native edit associations stay blank.
Research-key behavior is preserved. Intent collection still deferred.

Important validation status: build/test request was auto-review REJECTED with
"usage limit" before shell execution; do not claim compilation, simulator tests,
or main app installation succeeded. User instruction to keep finishing authorized
remaining work but does not fix the review-service quota. Do not work around the
rejection via another execution route. Completed safe source checks: xcodegen,
Swift frontend parse only, source/entry registration, diff whitespace, CSV-schema
validation. New tests NativeKeyboardTapTests (3) and SessionMetaTests addition
are unexecuted. Last actual simulator unit pass (54) predates native integration.

Asked user to Stop & export probe CSV and dismiss share sheet; read-only device
file query then reported specified device not found. Physical-probe CSV has NOT
been retrieved; only user count report and separately measured simulator CSV exist.
Updated probe README to reflect this evidence boundary.

Uploaded native schema example (converted from the measured simulator CSV,
explicitly not participant/phone data or integrated app output) and explanation
to existing Drive examples folder. CSV file ID 1WMt0MibrA7tOJ158joZsk4sz-DHKdG8N;
README file ID 1w5l9a87MUPC--_Rh_5refm-GClM6FkdU. New local files in
experiments/AppleKeyboardProbe/evidence/EXAMPLE_native_taps.csv and
README_native_example.txt. Upload and metadata readback verified.

Next: when tool quota/device availability permit, run FreeTypeRecorder scheme
simulator test + build, fix any failures, retrieve physical-probe CSV, and verify
integrated native keyboard capture through the real full recording flow. Do not
claim main app deployment or end-to-end verification until those happen.

## Physical-phone CSV received and verified

User supplied /Users/jimmy2/Downloads/native-keyboard-probe-1789135198.csv.
Verified all 13 rows: 7 touch_down, 6 text_change; monotonic finite timestamps,
finite points within keyboard frame (0,539,402,335), all touch source windows
UIRemoteKeyboardWindow. Text sequence Q,Qw,Qwe,Qw,Q,empty. First three screen
points (28.6667,618.3333),(67,615.6667),(99.3333,622); native keyboard-local
points (28.6667,79.3333),(67,76.6667),(99.3333,83). Final touch has no edit,
confirming that the raw touch stream must not imply a text edit for every touch.
Preserved byte-identical evidence/phone-native-keyboard-probe-1789135198.csv;
SHA256 08e70d7565e15408643fff88a4b3f2af0584560b808b5069bdc2bde4e30034ea.
Updated README evidence status from user report to verified physical export.
Integrated app build/runtime remains separately pending. Retrying only the normal
approval path; no workaround of the prior quota rejection.

## 2026-09-11 — Integrated native collector built and tested

The normal approval retry succeeded; the earlier review-service quota rejection
is resolved. FreeTypeRecorder simulator suite passed: 58 tests, 0 failures,
including native observation/filtering, CSV geometry and metadata compatibility.
Result bundle: /tmp/freetype-native-tests.xcresult; log: /tmp/freetype-native-tests.log.
Signed generic iOS build succeeded with BroadcastExtension, and strict deep
codesign verification passed. Log: /tmp/freetype-native-device.log.
Installed and launched integrated app in iOS 26.1 simulator; visually verified
Welcome screen. Screenshot: /tmp/freetype-native-startup.png.
Saved signed development IPA: build/native-keyboard/FreeTypeRecorder-native-keyboard.ipa.
ZIP integrity and main executable/embedded extension presence verified.
The iPhone remains unavailable to devicectl. Main-app physical installation and
full broadcast/capture/save/backup verification are still pending connection.
The supplied hardware CSV verifies the isolated probe, not the main recording flow.
Intent/error classification remains deferred.

## 2026-09-11 — Integrated simulator mouse-click validation passed

Both Debug simulator builds succeeded. Camera/broadcast prevent normal simulator
sessions, so a --keyboard-click-test route (DEBUG && targetEnvironment(simulator))
uses the production UIApplication observer, LoggingTextView and CSV logger directly.
This route creates test-only local output, excluding camera/broadcast/IMU/upload.
The production phone route is unaffected by the compile-time guard.

CUA connection initially timed out; rebooting simulated iOS restored AX control.
Coordinate mouse clicks then returned noWindowsAvailable while AX key activation
inserted text with zero touches. Restarting macOS Simulator itself restored direct
mouse input. The decorative editor overlay was removed while investigating focus;
software keyboard displayed after toggling Simulator's keyboard control.

Direct clicks produced Qwe with 3 measured taps; tested delete, retyping and Apple
prediction-bar selection. One click during prediction updates produced a t edit;
retained observed result without key/intent inference. Final 8 actual keyboard
region touch-downs, 9 text edits, final text 'question '. Editor-area click did not
increase count. Saved via production logger, copied unmodified to
experiments/AppleKeyboardProbe/evidence/integrated-simulator-ios18/.
CSV validation passed: 23 tap fields, native source/window, contiguous IDs,
monotonic finite times, measured points in bounds and exact screen/local mapping,
blank unknown Apple key geometry and blank native edit associations. Replaying
all edit rows matched final_text.txt exactly. Screenshots in
build/native-keyboard/click-test/. No fabricated contacts, participant sessions or
cloud upload. Full physical recording/broadcast/backup flow still unverified.

## Native autocorrect demonstration after custom-keyboard screenshot

User showed screenshot matching custom research keyboard and asked for genuine Apple keyboard/autocorrect. Opened existing native-mode simulator test without rebuilding. Direct clicks T/e/h showed Teh with Apple suggestion the; direct space click automatically changed text to the + space while tap count reached 4. Saved and verified actual production exports in evidence/integrated-simulator-autocorrect, including full edit replay and valid local/screen coordinates. Before/after screenshots saved to build/native-keyboard/autocorrect-test. No keyboard implementation change was needed; native is already the default. Phone install/full workflow still pending.

## 2026-09-11 — Custom keyboard removed; native-only collector verified

Removed FreeTypeRecorder's ResearchKeyboardView, KeyTapSample, KeyboardMode,
mode picker/state propagation, custom insertion callback and custom tap/edit joins.
NativeKeyboardTapSample is now its own logic file. Apple keyboard is the sole
input path and tap recording is automatic. TypingResearch's separate keyboard
implementation and all existing session data remain untouched. CSV column order
is preserved; unknown Apple key geometry and native edit associations stay blank.
Metadata still exports keyboardMode=system for reader compatibility.

Regenerated Xcode project. Replaced obsolete custom-keyboard tests with native
editor trait coverage; retained native geometry, session/reset and unmeasured-edit
checks. All 51 current simulator tests PASSED (0 failures). The earlier total of
58 included tests for the now-removed keyboard; this is not a skipped-test result.
Result: /tmp/freetype-apple-only-tests.xcresult.
Signed generic iPhone build SUCCEEDED; strict deep signature verification passed.
Updated build/native-keyboard/FreeTypeRecorder-native-keyboard.ipa and verified ZIP
integrity. Device is still unavailable, so physical installation/full broadcast
verification remains pending. Updated current README/protocol/data dictionary;
historical test evidence and past custom exports remain documented as historical.
