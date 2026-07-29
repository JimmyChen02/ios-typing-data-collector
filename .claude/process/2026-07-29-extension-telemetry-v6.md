# 2026-07-29 — Keyboard extension telemetry v6

**Context:** `feature/systemwide-adaptive-keyboard`; expand the encrypted
keyboard-extension ledger for preliminary ML/error and Gaussian-boundary work.

**Attempted:** Added schema-v6 typed payloads, complete touch trajectories,
before/after edit lineage, prediction offers/outcomes, latency, environment and
layout snapshots, JSONL export controls, documentation, and compatibility tests.

**Errors:** The first generic simulator build failed on inferred `compactMap`
result types in emoji geometry. The second failed because
`environmentSnapshot()` omitted an explicit `return`. Both were fixed. Unit
tests then exposed that the current SymSpell-frequency decoder chooses `held`
for `helo`, while an existing test expects `hello`.

**Fix / outcome:** Generic simulator build succeeds. New schema-v6 round-trip
and v5 backward-decode tests pass. The complete core suite has one remaining
language-model behavior failure unrelated to telemetry.

**Notes for next agent:** iOS cannot identify whether an external host mutation
came from a user or LLM, so those events are stored as external/unknown. Emoji
gesture recognizers expose coordinates and timing but not `UITouch` pressure,
radius, or precise coordinates.
