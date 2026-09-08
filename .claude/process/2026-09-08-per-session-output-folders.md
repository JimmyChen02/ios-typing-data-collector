# 2026-09-08 — Group free-type outputs by raw session

## Change

Both free-type scripts now write each raw export's artifacts into one folder:

`processed-keystrokes/<session>/`

- `substitution_metrics.py` writes `<session>_processed.csv` and
  `<session>_summary.md` there.
- `word_edit_metrics.py` writes `<session>_word_edits.csv` and
  `<session>_word_summary.md` in the same folder.

Explicit `--labeled-out` paths remain unchanged. Cross-session outputs passed
via `--out` or `--joint-out` remain wherever those explicit paths name them;
they do not belong to one raw export.

## Migration and verification

Moved existing individual derived artifacts for `Jimmy_test_Tran`,
`Tran_Tran_test1`, and the four Jimmy hand sessions into their matching
folders. Regenerated the four Jimmy word reports after the raw names changed,
so their output filenames use `jimmy_keystrokes_1` through
`jimmy_keystrokes_4`; removed only the superseded `jimmy_1` through `jimmy_4`
derived files. Raw exports were not changed.

Verified compilation of both scripts and a direct CLI run: one raw export
creates all four expected files in the same session folder. The full pytest
suite remains unavailable in the checked-in virtual environment because
`pytest` is not installed.
