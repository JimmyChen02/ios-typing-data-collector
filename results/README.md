# results/ — Analysis Output Bundles

Dated bundles of generated artifacts (cleaned CSVs, tap PDFs, Gaussian boundaries,
loss charts) so outputs stay separate from input/test data in `csv_threshold_test/`.

Convention: one subdir per run, `YYYY-MM-DD-<participant-or-purpose>/`. Keep the
exact command used in a small `run.md` inside the bundle (and/or log it in
`.claude/process/`).

Large binary artifacts here are generally not committed — see `.gitignore`.
