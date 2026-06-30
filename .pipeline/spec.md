# Spec: Smooth circular progress ring during holding-hand capture

## OPEN QUESTIONS
None blocking. Defaults chosen below; flagged inline as DEFAULT so they can be overridden:
- DEFAULT: ring color is `.orange` for all three conditions (matches the existing app accent and the current ring). Not per-condition. Override only if per-hand color is wanted.
- DEFAULT: center of ring shows the remaining-seconds countdown (`secondsRemaining`), same as today. No checkmark-on-completion swap. Override only if a completion checkmark is desired.

## Summary of what this is
`TypingResearch/Views/HandCaptureView.swift` ALREADY draws a progress ring inside
`capturingView(hand:)` (lines ~181-202). It is driven off `secondsRemaining` and
animated with `.animation(.linear(duration: 1), value: secondsRemaining)`.

The problem: `secondsRemaining` only changes once per second (in the `countdownTask`
`for` loop), so the ring fills in 30 discrete 1-second steps rather than a smooth
sweep. The request is a SMOOTH fill from empty to full over the capture duration.

This is a purely additive/visual change. Do NOT touch capture timing, frame saving,
`finishCondition`, `startCondition` advancement, `studySessionIndex`, `onComplete`,
the `.id(hand)` modifier, the `countdownTask`, or `HandBurstCapture`.

## File to modify
`/Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector/TypingResearch/Views/HandCaptureView.swift`

NO new files. Add the ring as a `private` subview/computed property inside the
existing `HandCaptureView` struct so `project.pbxproj` is untouched.

## Approach: drive the ring off `secondsRemaining` (existing source of truth)

Keep `secondsRemaining` as the single source of truth — it is what the real
countdown task drives and what already resets cleanly per condition (set to
`captureSeconds` in `startCondition`, decremented in `countdownTask`). Do NOT add a
separate timer or `TimelineView` clock that could drift from the real capture.

To make the fill smooth despite the 1-second granularity of `secondsRemaining`,
compute the progress fraction from `secondsRemaining` and animate with a
1-second linear animation keyed on `secondsRemaining`. Because each 1-second step
animates linearly over exactly 1 second to the next step, the visible sweep is
effectively continuous and stays locked to the real countdown. This is the minimal,
drift-free implementation.

### Add a computed progress property (new, inside the struct)
```swift
/// 0...1 fill fraction for the capture ring, derived from the real countdown
/// so it cannot drift from actual capture timing. Resets to 0 each condition
/// because secondsRemaining is reset to captureSeconds in startCondition.
private var captureProgress: CGFloat {
    let total = CGFloat(captureSeconds)
    guard total > 0 else { return 0 }
    let elapsed = total - CGFloat(secondsRemaining)
    return min(max(elapsed / total, 0), 1)
}
```
Note: at condition start `secondsRemaining == captureSeconds` -> progress 0 (empty);
after the last tick `secondsRemaining == 0` -> progress 1 (full). Verified against the
`stride(from: captureSeconds - 1, through: 0, by: -1)` loop in `beginCapture`.

### Replace the existing ring ZStack (current lines ~181-202)
Replace the `// Progress ring / countdown` ZStack block with one that trims to
`captureProgress` and animates linearly keyed on `secondsRemaining`:

```swift
// Progress ring / countdown
ZStack {
    Circle()
        .stroke(Color(.systemGray5), lineWidth: 12)
        .frame(width: 140, height: 140)

    Circle()
        .trim(from: 0, to: captureProgress)
        .stroke(Color.orange, style: StrokeStyle(lineWidth: 12, lineCap: .round))
        .frame(width: 140, height: 140)
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 1), value: secondsRemaining)

    VStack(spacing: 4) {
        Text("\(secondsRemaining)")
            .font(.system(size: 48, weight: .bold, design: .monospaced))
            .foregroundColor(.primary)
        Text("seconds")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
```

This keeps the SAME visual style (orange stroke, gray track, 140pt, round cap,
-90 degrees start at top, centered monospaced countdown) — the only behavioral
change is that `trim` now reads the `captureProgress` helper. Functionally this is
close to today's inline expression, so if the existing stepped behavior is judged
acceptable the diff is minimal; the helper is the cleaner source-of-truth form.

## Edge cases the implementation MUST handle
1. Reset per condition: `startCondition(_:)` already sets `secondsRemaining =
   captureSeconds` BEFORE `phase = .capturing(hand)`, and the capturing branch
   carries `.id(hand)`. With progress derived from `secondsRemaining`, the ring is
   guaranteed to read 0 (empty) at the start of left, right, and both. Do not add
   any extra reset logic; rely on the existing reset.
2. Reads full at end: after the final countdown tick `secondsRemaining` reaches 0,
   so `captureProgress` reaches 1 before `finishCondition` advances. Do not gate the
   ring on `finishCondition`.
3. Camera unavailable: when `onUnavailable` fires it cancels `countdownTask`, so
   `secondsRemaining` freezes and the ring simply stops mid-fill. That is correct —
   do not special-case it.
4. Clamp: keep the `min/max` clamp in `captureProgress` so a stray
   `secondsRemaining` value can never produce a trim outside 0...1.
5. Do NOT animate on `captureProgress` directly via `.animation(_, value:)` (it is a
   CGFloat with no `Equatable` identity issue, but keying on `secondsRemaining` is
   what ties the animation to real ticks). Key the `.animation` modifier on
   `secondsRemaining`, exactly as the current code does.

## Pattern to follow
Copy the visual idiom directly from the existing ring in the same file
(`HandCaptureView.capturingView(hand:)`, the `// Progress ring / countdown`
ZStack) and the orange-accent style used throughout `introView` / `reviewingView`.
No new colors, fonts, or sizes.

## Out of scope (do not change)
- `TypingResearch/Services/HandBurstCapture.swift` (capture logic, throttling).
- `targetFPS`, `captureSeconds`, `countdownTask` loop, frame saving / `saveFrame`,
  `studySessionIndex`, manifest schema, Python/training code.
- `project.pbxproj` (no new files).
- The `frameIndex` "frames captured" block below the ring stays as-is.
</content>
</invoke>
