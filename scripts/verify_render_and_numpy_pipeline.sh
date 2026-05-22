#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_BASE="${1:-/private/tmp/typing-research-verify}"

SESSION_DIR="$OUTPUT_BASE/session-overlap-check"
GT_DIR="$OUTPUT_BASE/gt-check"
BACKOFF_DIR="$OUTPUT_BASE/backoff-check"

mkdir -p "$SESSION_DIR" "$GT_DIR" "$BACKOFF_DIR"

cd "$ROOT_DIR"

echo "Compiling Python scripts..."
python3 -m py_compile scripts/*.py

echo "Running synthetic Gaussian/session render checks..."
python3 scripts/session_overlap_visualization.py --demo --output-dir "$SESSION_DIR"
python3 scripts/gaussian_keyboard_pdf.py "$SESSION_DIR/synthetic_session_overlap_input.csv" "$SESSION_DIR/demo_gaussian.pdf"
python3 scripts/gaussian_keyboard_pdf.py "$SESSION_DIR/synthetic_session_overlap_input.csv" "$SESSION_DIR/demo_gaussian.svg"

echo "Running synthetic analysis checks..."
python3 scripts/manual_test_ground_truth_trial_loss.py --output-dir "$GT_DIR"
python3 scripts/manual_test_key_backoff_report.py --output-dir "$BACKOFF_DIR"
python3 scripts/future-trial-loss.py "$GT_DIR/synthetic_ground_truth_trial_loss_input.csv" --output-prefix synthetic_future_check
python3 scripts/loss-automation.py "$GT_DIR/synthetic_ground_truth_trial_loss_input.csv" --output-prefix synthetic_overlap_check

echo
echo "Verification complete."
echo "Session outputs: $SESSION_DIR"
echo "Ground-truth outputs: $GT_DIR"
echo "Backoff outputs: $BACKOFF_DIR"
