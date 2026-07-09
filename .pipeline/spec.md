# Spec: Typing test field in Live Posture Demo

## Goal
Add a text input at the bottom of the Live Posture Demo screen so the user can
type with the on-screen iOS keyboard while the live posture prediction card
stays visible. Purpose: manually confirm the IMU classifier's left / right /
both predictions react correctly while actually typing in different postures.
This is a demo aid, NOT a data-collection surface — nothing is logged or
persisted.

## Files to modify
- `TypingResearch/Views/LivePostureDemoView.swift` — the only code file to touch.
- `docs/POSTURE_DEMO.md` — add one short note that the demo screen now has a
  typing field (see "Docs" below).
- `build_log.md` — add a new entry (repo rule; see "Build verification").

Do NOT create new files. Do NOT touch SessionManager, SessionView, model
files, or anything under `Model-Training-Test/` — the working tree already has
unrelated pending changes there that must be left exactly as-is.

## Current layout (what you are editing)
`LivePostureDemoView.body` is a `ZStack`:
1. `Color.black.ignoresSafeArea()`
2. Camera preview (`LiveDemoPreviewView`, `.ignoresSafeArea()`) or an
   "unavailable" placeholder.
3. A `VStack` overlay: close button (top-right `xmark.circle.fill` that calls
   `dismiss()`), a `Spacer()`, then `predictionCard`, `.padding(.bottom, 24)`.

`.onAppear` starts the camera, `MotionRecorder.shared.startMonitoring()`, and
`predictor.start()`. `.onDisappear` reverses all three. Keep this lifecycle
untouched — the IMU pipeline is independent of UIKit text input, so raising the
keyboard does not interfere with motion sampling or prediction.

The view uses `PosturePredictor.shared` and holds no `SessionManager`. It does
not need one; do not add one.

## Implementation

### 1. Text field
Add a `@State private var typedText: String = ""` and a
`@FocusState private var typingFocused: Bool`.

Use a **plain SwiftUI `TextField`**, not `LoggingTextField`. Justification:
`LoggingTextField` (UIViewRepresentable) requires `onEvent` / `buildEventData`
closures wired to `InputEvent`/session logging and force-`becomeFirstResponder()`
on appear — all irrelevant here and would pull session plumbing into a
zero-persistence demo. A plain `TextField` with autocorrect/autocapitalization
disabled gives the same "study keyboard" typing feel without the logging hooks.

Configure the field to mirror the study keyboard behavior:
```swift
TextField("Type here to test each hand posture\u{2026}", text: $typedText)
    .textFieldStyle(.plain)
    .autocorrectionDisabled(true)
    .textInputAutocapitalization(.never)
    .keyboardType(.asciiCapable)
    .focused($typingFocused)
    .submitLabel(.done)
    .onSubmit { typingFocused = false }
```
Wrap it in a rounded `.ultraThinMaterial` background bar so it reads over the
camera feed (match the prediction card's material/corner treatment, e.g.
`RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)` with internal
padding). White foreground text.

### 2. Clear + dismiss controls
Alongside the text field (trailing side of the input bar), add:
- A **clear** control (e.g. `xmark.circle.fill` button) that sets
  `typedText = ""`. Show it only when `!typedText.isEmpty`.
- A **Done / dismiss-keyboard** control that sets `typingFocused = false`,
  shown only when `typingFocused` is true (or always — either is fine). This
  gives the user a way to drop the keyboard and see the full-screen camera
  again. Dismissing the keyboard must NOT clear the text (separate from clear).

### 3. Layout / keyboard avoidance (the critical part)
When the keyboard is raised the prediction card must remain visible above it.

- Put the input bar at the bottom of the overlay `VStack` (below
  `predictionCard`), so the layout order top-to-bottom is: close button,
  `Spacer()`, `predictionCard`, input bar.
- Do NOT apply `.ignoresSafeArea(.keyboard)` to the overlay `VStack` — you WANT
  SwiftUI's default keyboard avoidance to push the overlay content (card + input
  bar) up above the keyboard. Keep the camera preview / black background on
  `.ignoresSafeArea()` so only the camera stays full-bleed while the overlay
  lifts.
- Result: with the keyboard down, card sits near the bottom as today and the
  input bar sits just below it; with the keyboard up, both card and input bar
  ride up above the keyboard and stay visible. The camera preview does not need
  to shrink — it stays full-screen behind the (now-shorter visible) overlay.
- Reduce or drop the current `predictionCard`'s `.padding(.bottom, 24)` if it
  causes the card to sit too far from the input bar; keep spacing tight so both
  fit above the keyboard on an iPhone 16-class screen.
- Give the whole overlay `VStack` a small horizontal padding consistent with the
  existing `.padding(.horizontal, 24)` used inside `predictionCard`.

### 4. Tap-to-dismiss (optional, low risk)
Optionally add a `.onTapGesture { typingFocused = false }` to the black
background so tapping the camera area dismisses the keyboard. Only add this if
it does not swallow the close button / clear button taps (those are on top in
the ZStack, so they should still receive taps). If uncertain, skip it — the
Done control already covers dismissal.

## Edge cases the implementation must handle
- **Camera unavailable (Simulator):** the input bar + prediction card must still
  render and be usable when `cameraUnavailable == true`. Do not nest the input
  bar inside the `else` (camera-available) branch — it lives in the overlay
  `VStack`, which draws regardless of camera state.
- **No Core ML model bundled:** the prediction card already shows the "No Core
  ML model bundled" state; the typing field must not depend on
  `predictor.isModelAvailable` and must remain functional.
- **Keyboard raised then screen dismissed:** dismissing the fullScreenCover (via
  the close button) while the keyboard is up must still run `.onDisappear`
  cleanup normally. Since the close button calls `dismiss()`, no special
  handling is needed — just do not gate `dismiss()` on focus state.
- **Empty text:** clear button hidden when text is empty; no crash on clearing
  already-empty text.
- **Long typed text:** the field is single-line; long input should scroll within
  the field, not push the layout. A plain single-line `TextField` handles this.

## Patterns to follow
- Material card styling: copy the look from `predictionCard` in the same file
  (`.ultraThinMaterial`, `RoundedRectangle(cornerRadius:)`, padding).
- Autocorrect/caps-off intent: mirror `LoggingTextField.makeUIView`
  (`autocorrectionType = .no`, `autocapitalizationType = .none`,
  `keyboardType = .asciiCapable`) — but express it with SwiftUI modifiers as in
  section 1, do not import/use `LoggingTextField`.
- Close button pattern: reuse the existing `xmark.circle.fill` white/opacity
  styling already in the view for the clear button.

## Build verification (repo rule)
After implementing, run:
```sh
xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.3.1' build
```
It must reach `** BUILD SUCCEEDED **`. Then append a new dated entry to
`build_log.md` following the existing format (Change / Files touched / Command /
Errors / Result). Note in it that the change is scoped to `LivePostureDemoView`
and adds no logging/persistence.

## Docs
In `docs/POSTURE_DEMO.md`, add a brief note (in "5. Record the demo" or "Notes")
that the Live Posture Demo screen now includes a bottom typing field so you can
type in each posture while watching the live tag — no keystrokes are logged.
Keep it to 1-2 sentences.
