# Spec: Move "Free Writing Mode" button under "Start Study"

## OPEN QUESTIONS
None. Both viable styling choices are covered under DECISIONS; neither materially blocks implementation.

## DECISIONS
- **Placement**: Move the entire `Section { ... }` that currently wraps the "Free Writing Mode" button (currently lines 151-169) so it sits **immediately after** the "Start Study" `Section` (currently lines 92-109) and **before** the "Posture Training Run" `Section` (currently lines 111-129). "Directly under Start Study" is interpreted as the very next Form section, which renders directly below the Start Study button. Keeping it as its own `Section` (rather than merging into the Start Study section) preserves the existing footer text and matches the sibling opt-in buttons.
- **Styling**: **Unchanged.** Keep the current secondary styling (`.listRowBackground(Color(.systemGray6))`, `.fontWeight(.semibold)` title + `.caption2`/`.secondary` subtitle, `.padding(.vertical, 4)`). Free Writing Mode remains a secondary/opt-in mode like Posture Training Run and Live Posture Demo; it should not adopt the orange prominent styling reserved for the primary Start Study action. Reason: the request is a positioning tweak, not a visual promotion.
- **Presentation logic**: **Do not move.** The `.fullScreenCover(isPresented: $showFreeWriting)` modifier (lines 175-177), the `@State private var showFreeWriting` (line 27), and the `startFreeWriting()` method (lines 266-286) are all attached to the `Form`/`NavigationStack` or are view-level members, not to the Free Writing `Section`. Reordering the section does not require touching any of them.
- **Behavior / validation**: **Unchanged.** No enabled/disabled condition is tied to the Free Writing button today (there is no `.disabled(...)` on it, and `startStudy`/`startFreeWriting` both default empty names to "Anonymous"). The new position does not make any condition wrong, so preserve behavior exactly.

## FILE TO MODIFY
- `/Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector/TypingResearch/Views/ParticipantSetupView.swift`

This is the only file to change. No new files.

## EXACT CHANGE
Reorder the sections inside the `Form` so the order becomes:

1. `Section("Participant Information")`
2. `Section("Study Setup")`
3. `Section("Device Info")`
4. `Section { Button(action: startStudy) ... }`  (Start Study — unchanged)
5. `Section { Button(action: startFreeWriting) ... }`  (Free Writing Mode — MOVED HERE, unchanged content)
6. `Section { Button(action: { showPostureSelect = true }) ... }`  (Posture Training Run — unchanged)
7. `Section { Button(action: { showLiveDemo = true }) ... }`  (Live Posture Demo — unchanged)

Concretely: cut the Free Writing `Section` block (the section beginning `Section {` with `Button(action: startFreeWriting)` and ending with its `} footer: { Text("Type freely ...") }` — currently lines 151-169) and paste it verbatim immediately after the Start Study section's closing brace (currently the `}` on line 109), before the "Posture Training Run" section. Do not alter the block's contents.

## PATTERN TO FOLLOW
Match the existing sibling sections already in this same file — the Start Study, Posture Training Run, and Live Posture Demo sections are all standalone `Section { Button ... } footer: { ... }` blocks. This is a pure reorder of an existing, correctly-styled block; copy nothing new.

## EDGE CASES / CONSTRAINTS
- Do not duplicate the Free Writing section — it must appear exactly once.
- Leave the `.fullScreenCover(isPresented: $showFreeWriting)` modifier and all other view modifiers (`.sheet`, `.onReceive`, `.alert`, `.navigationTitle`) untouched and in place.
- Leave `showFreeWriting` state and `startFreeWriting()` untouched.
- No changes to `SessionManager` or `FreeWritingView`.
- Preserve exact string content, footer text, spacing values, and `.listRowBackground` color of the moved block.

## VERIFICATION
- App builds: `xcodebuild -scheme TypingResearch`.
- Existing `TypingResearchTests` target should be unaffected (no logic changed). No new tests required for a layout reorder.
- Manual/visual: in the setup screen, the "Free Writing Mode" button now renders directly below the orange "Start Study" button, retaining its gray secondary appearance and footer text; tapping it still presents `FreeWritingView` full-screen.
