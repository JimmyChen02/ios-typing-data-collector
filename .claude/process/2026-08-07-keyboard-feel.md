# 2026-08-07 — Keyboard feel and LM behavior

**Context:** Fast typing missed/mis-registered keys; size/haptics felt wrong;
LM appeared to autocomplete on its own; Gaussian routing distracted from the
keyboard fidelity goal.

**Root causes:**
1. Single-touch only (`isMultipleTouchEnabled = false`) dropped overlapping taps.
2. SwiftUI `updateUIView` rewrote `localText` from a lagging parent binding mid-burst.
3. Autocorrect-on-space was easy to confuse with autocomplete; completions must stay
   tap-to-accept.
4. Keyboard height depended on a system-keyboard measurement that never fires for
   the in-app keyboard.

**Fixes:** Multi-touch + secondary-touch commit; ignore parent text when local is
ahead; classic-only path; iOS-like suggestion bar (`“typed”` / correction /
alternate); stricter spelling-only autocorrect; fixed 292pt height; playground
screen with CSV export of suggestions offered/selected.

**Outcome:** Simulator build succeeded.
