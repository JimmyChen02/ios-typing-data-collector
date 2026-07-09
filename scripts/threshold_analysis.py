#!/usr/bin/env python3
"""
threshold_analysis.py
---------------------
Analyzes the cleaned keystroke CSV to:
  1. Document how unintended inputs were found
  2. Show the dist_from_target_kw distribution
  3. Run threshold sensitivity (how many taps excluded at each cutoff)
  4. Surface hard-to-tell borderline cases

Usage:
    python threshold_analysis.py <cleaned.csv>
"""

import sys
import csv
from pathlib import Path
from collections import defaultdict

THRESHOLDS = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
CURRENT_DIST_THRESHOLD = 1.25
CURRENT_SPATIAL_MAX    = 1.5

def safe_float(val, default=None):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default

def load_rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))

def is_analysis_candidate(row):
    """Exclude trial_start, delete_event, and rows with no tap data."""
    flags = row.get("outlier_flags", "")
    if "trial_start" in flags or "delete_event" in flags:
        return False
    if row.get("event_type", "").strip().lower() == "delete":
        return False
    if not row.get("key_label", "").strip():
        return False
    return True

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    rows = load_rows(sys.argv[1])
    candidates = [r for r in rows if is_analysis_candidate(r)]
    total = len(candidates)

    print("=" * 62)
    print("  UNINTENDED INPUT & THRESHOLD ANALYSIS")
    print("=" * 62)
    print(f"\nTotal events in CSV      : {len(rows)}")
    print(f"Excluding trial_start / delete : {len(rows) - total}")
    print(f"Analysis candidates      : {total}")

    # ── 1. Unintended inputs: key_label ≠ expected_char ─────────────────────
    mistaps = [r for r in candidates
               if r.get("key_label","").strip().lower() !=
                  (r.get("expected_char","").strip().lower()
                   .replace(" ", "space"))]
    print(f"\n── 1. MISTAPS (tapped key ≠ intended key) ──────────────────")
    print(f"  Count: {len(mistaps)} / {total}  ({100*len(mistaps)/total:.1f}%)")

    # Bucket mistaps by distance
    buckets = {"inside (0)": 0, "0–0.5 kw": 0, "0.5–1.0 kw": 0,
               "1.0–1.25 kw": 0, "1.25–1.5 kw": 0, "> 1.5 kw": 0, "no dist": 0}
    mistap_examples = defaultdict(list)
    for r in mistaps:
        d = safe_float(r.get("dist_from_target_kw"))
        exp = r.get("expected_char","?").strip()
        hit = r.get("key_label","?").strip()
        key = f"{exp}→{hit}"
        if d is None:
            buckets["no dist"] += 1
        elif d == 0:
            buckets["inside (0)"] += 1
            mistap_examples["inside (adjacent key overlap)"].append((key, d))
        elif d <= 0.5:
            buckets["0–0.5 kw"] += 1
            mistap_examples["near neighbor (0–0.5 kw)"].append((key, d))
        elif d <= 1.0:
            buckets["0.5–1.0 kw"] += 1
            mistap_examples["neighbor mistap (0.5–1.0 kw)"].append((key, d))
        elif d <= 1.25:
            buckets["1.0–1.25 kw"] += 1
            mistap_examples["borderline (1.0–1.25 kw)"].append((key, d))
        elif d <= 1.5:
            buckets["1.25–1.5 kw"] += 1
            mistap_examples["far mistap (1.25–1.5 kw)"].append((key, d))
        else:
            buckets["> 1.5 kw"] += 1
            mistap_examples["unintended (> 1.5 kw)"].append((key, d))

    for label, count in buckets.items():
        if count:
            print(f"    {label:<25} {count:>4}  ({100*count/total:.1f}%)")

    print("\n  Sample mistap pairs per distance band:")
    for band, examples in mistap_examples.items():
        freq = defaultdict(int)
        for key, _ in examples:
            freq[key] += 1
        top = sorted(freq.items(), key=lambda x: -x[1])[:5]
        top_str = ", ".join(f"{k}({n})" for k, n in top)
        print(f"    [{band}]  {top_str}")

    # ── 2. dist_from_target_kw distribution (all candidates) ────────────────
    dists = [safe_float(r.get("dist_from_target_kw"))
             for r in candidates]
    dists_valid = [d for d in dists if d is not None]

    dist_bands = [
        ("inside key (0.0)",    lambda d: d == 0.0),
        ("0.0–0.5 kw",          lambda d: 0.0 < d <= 0.5),
        ("0.5–1.0 kw",          lambda d: 0.5 < d <= 1.0),
        ("1.0–1.25 kw",         lambda d: 1.0 < d <= 1.25),
        ("1.25–1.5 kw",         lambda d: 1.25 < d <= 1.5),
        ("1.5–2.0 kw",          lambda d: 1.5 < d <= 2.0),
        ("> 2.0 kw",            lambda d: d > 2.0),
    ]
    print(f"\n── 2. DISTANCE FROM INTENDED KEY (all {total} candidates) ──")
    for label, fn in dist_bands:
        count = sum(1 for d in dists_valid if fn(d))
        pct = 100 * count / total
        bar = "█" * int(pct / 2)
        print(f"  {label:<22} {count:>5}  ({pct:5.1f}%)  {bar}")

    no_dist = total - len(dists_valid)
    if no_dist:
        print(f"  {'no dist data':<22} {no_dist:>5}  ({100*no_dist/total:.1f}%)")

    # ── 3. Threshold sensitivity ─────────────────────────────────────────────
    print(f"\n── 3. THRESHOLD SENSITIVITY (far_from_target only) ─────────")
    print(f"  {'Threshold':<12} {'Excluded':>10} {'% of total':>12}  note")
    for t in THRESHOLDS:
        excluded = sum(1 for d in dists_valid if d > t)
        marker = " ← current" if t == CURRENT_DIST_THRESHOLD else ""
        print(f"  > {t:<9} {excluded:>10} {100*excluded/total:>11.1f}%{marker}")

    # ── 4. Hard-to-tell borderline cases ────────────────────────────────────
    # Taps near the current threshold (±0.25 kw)
    borderline = [r for r in candidates
                  if safe_float(r.get("dist_from_target_kw")) is not None
                  and abs(safe_float(r.get("dist_from_target_kw")) - CURRENT_DIST_THRESHOLD) <= 0.25]

    print(f"\n── 4. HARD-TO-TELL CASES (dist within ±0.25 of threshold) ─")
    print(f"  {len(borderline)} taps between {CURRENT_DIST_THRESHOLD-0.25:.2f} and "
          f"{CURRENT_DIST_THRESHOLD+0.25:.2f} kw from intended key")
    freq = defaultdict(int)
    for r in borderline:
        exp = r.get("expected_char","?").strip()
        hit = r.get("key_label","?").strip()
        freq[f"{exp}→{hit}"] += 1
    top = sorted(freq.items(), key=lambda x: -x[1])[:10]
    for pair, count in top:
        exp, hit = pair.split("→")
        correct = "✓ same key" if exp == hit or (exp == " " and hit == "space") else "✗ wrong key"
        print(f"    {pair:<12} {count:>4}x  {correct}")

    # ── 5. Recommendation ────────────────────────────────────────────────────
    print(f"\n── 5. RECOMMENDATION ───────────────────────────────────────")
    far_1_5 = sum(1 for d in dists_valid if d > 1.5)
    far_1_25 = sum(1 for d in dists_valid if d > 1.25)
    far_1_0 = sum(1 for d in dists_valid if d > 1.0)
    print(f"  Current threshold (1.25 kw) excludes {far_1_25} taps ({100*far_1_25/total:.1f}%)")
    print(f"  Tightening to 1.0 kw would add {far_1_0 - far_1_25} more exclusions")
    print(f"  Loosening to 1.5 kw would keep {far_1_25 - far_1_5} currently-excluded taps")
    print()
    print("  If goal is to exclude UNINTENDED inputs only:")
    print("    → Keep 1.0–1.25 kw. Adjacent key mistaps (dist ≈ 0)")
    print("      are LEGITIMATE near-misses and should stay in.")
    print("    → Flag anything > 1.0 kw as suspect; > 1.5 kw as definite outlier.")
    print()
    print("  Spatial threshold [-0.5, 1.5] on the HIT key is standard")
    print("  (Azenkot & Zhai 2012). Keep it unless you see many false positives.")
    print("=" * 62)


if __name__ == "__main__":
    main()
