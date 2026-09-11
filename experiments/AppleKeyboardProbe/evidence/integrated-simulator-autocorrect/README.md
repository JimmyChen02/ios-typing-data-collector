# Native Apple autocorrect + coordinate capture — 2026-09-11

Unmodified CSVs from FreeTypeRecorder’s production native editor, touch observer and logger in its DEBUG simulator-only click screen (iOS 18.3.1). Simulator mouse input, not participant data; camera/broadcast/IMU/upload excluded as recorded in test_meta.json.

Direct mouse clicks: T, e, h; onscreen text Teh and Apple’s selected suggestion the. Click space (not the suggestion): Apple automatically changed Teh to the and inserted a space. Exactly 4 measured touches were exported. Replaying the text-edit CSV reproduces final_text.txt exactly (the followed by a space). All native edit tap IDs/coordinates remain blank; measured coordinates are in taps.csv.

This validates native autocorrect and simultaneous x/y observation with the real Apple keyboard. The custom Research keyboard from the earlier UI examples does not provide autocorrect. The full physical recording/broadcast/backup flow remains separately pending.

Before/after screenshots: build/native-keyboard/autocorrect-test/ in the local workspace.
