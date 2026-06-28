# TypingResearch — Agent Instructions

## What this is
A **HCI typing-research project**. Goal: collect keystroke-level data from people
typing on an iPhone, then study how well an *adaptive* keyboard (probabilistic,
Gaussian key regions) reproduces the "feel" and accuracy of the stock iOS keyboard
versus a *classic* fixed-rectangle keyboard.

Two halves live in one repo:
1. **iOS app** (`TypingResearch/`) — runs timed typing sessions, logs every touch,
   and exports raw + cleaned data and review PDFs.
2. **Python analysis** (`scripts/`) — offline cleaning, visualization, and
   trial-loss / boundary analyses on exported CSVs.

## Core domain concepts
- **Keyboard modes:** `classic` = fixed rectangular key regions. `gaussian` =
  adaptive probabilistic regions fit per-key from a user's own taps.
- **Study designs:** `classic + adaptive` (first half of sessions classic, second
  half Gaussian trained on the classic data) and `classic only`.
- **Session/trial structure:** 15 trials per session, 8 random words each.
- **Data cleaning (`tap_norm_x/y`, outlier flags):** each tap is normalized into
  per-key local coordinates `(0..1)` within `[-0.5, 1.5]`; taps far from the target
  key are flagged as spatial outliers. Threshold defaults trace to Zhai (2012).
- **Gaussian cleaning / boundary:** each key gets a 2D Gaussian (`muX/muY` mean,
  inverse-covariance `pxx/pxy/pyy`) fit from its taps. A tap's **Mahalanobis
  distance** to the key center decides membership; the per-key boundaries (the
  "Gaussian boundary") define the adaptive keyboard. With enough trials the boundary
  stabilizes — the *ground-truth loss* analysis measures how many trials that takes.
  In-app model lives in `GaussianKeyModel` / `GaussianModelStore`
  (`Documents/gaussian_taps.json`).

## Architecture (iOS)
- **Stack:** Swift 5.9+, SwiftUI, SwiftData (iOS 17+). MVVM with `@Observable SessionManager`.
- **Persistence:** SwiftData; export to CSV/JSON for analysis.

## Directory map
- `TypingResearch/` — Swift app source
  - `Models/Models.swift` — SwiftData models: Participant, Session, Trial, InputEvent
  - `ViewModels/SessionManager.swift` — `@Observable` session state machine
  - `Views/` — `ParticipantSetupView`, `SessionView` (router), `TrialView`,
    `LoggingTextField` (UIViewRepresentable, keystroke logging; no autocorrect/caps/spellcheck)
  - `Services/` — `DataExporter` (CSV/JSON), `GaussianKeyModel`, `GaussianModelStore`,
    `KeystrokeCleaner` (in-app cleaning)
  - `Utilities/Utilities.swift` — DeviceInfo, WordGenerator, MetricsComputer
- `scripts/` — Python analysis pipeline (see `scripts/CLAUDE.md`)
- `csv_threshold_test/` — sample exports + cleaned variants at various thresholds (test data, gitignored-ish artifacts)
- `logs/`, `build_log.md` — xcodebuild logs and running build log
- `venv/` — Python venv for the scripts (matplotlib, numpy, pillow, etc.)
- `results/` — dated analysis output bundles (gitignored except README)
- `.claude/` — agent workspace (see below)

## Build
```sh
cd /Users/trantran/Hyunchul/ios-typing-data-collector
xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Open in Xcode: `open TypingResearch.xcodeproj`

## Conventions / notes
- iOS 17.0+ target. Bundle ID: `com.typingresearch.app`.
- `interKeyIntervalMs` is computed from `lastEventTimestamp` in SessionManager.
- **Always update `build_log.md`** on every build: changes, errors, fixes, result.
- Run Python from the repo root using `venv/`.

## Commit rule
Each commit is **concise but detailed** about its changes and **scoped to a single
feature change** (don't bundle unrelated work). **NEVER add a `Co-Authored-By: Claude`
trailer or any Claude attribution.** Only commit/push when asked.

## .claude/ workspace
- `.claude/agents/` — custom subagent definitions for this repo.
- `.claude/plans/` — saved implementation plans (one file per feature/task).
- `.claude/process/` — **run log.** Append an entry per significant run: what was
  attempted, errors hit, fixes, outcome. New agents read this for hard-won context.
- `.claude/decisions/` — ADR-style records of *why* parameters/designs were chosen.
- `.claude/data-dictionary.md` — canonical raw + cleaned CSV column schema.
- `.claude/glossary.md` — shared project vocabulary.
