#!/usr/bin/env bash
# merge_hand_export.sh — merge one phone export (zip or unzipped folder)
# into the flat training layout under Model-Training-Test/.
#
# Usage:
#   bash scripts/merge_hand_export.sh ~/Downloads/hand_export_Tran_.zip
#   bash scripts/merge_hand_export.sh ~/Downloads/hand_export_Tran_/
#
# What it does (see Model-Training-Test/model.md "Where downloaded exports go"):
#   1. Unzips / copies the raw export into Model-Training-Test/exports/<name>_<date>/
#      (untouched provenance copy).
#   2. Safety checks: exactly one manifest, header matches the combined
#      manifest exactly, no image-filename overlap with already-merged data
#      (catches double-merges).
#   3. Copies hand_images/* and imu/* into the shared flat folders and
#      appends the manifest's data rows to hand_manifest_combined.csv.
#   4. Prints per-participant / per-label counts of the combined dataset.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/Model-Training-Test"
COMBINED="$DEST/hand_manifest_combined.csv"
EXPORTS="$DEST/exports"
TODAY="$(date +%Y-%m-%d)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: bash scripts/merge_hand_export.sh <export.zip | export_folder>"
SRC="$1"
[ -e "$SRC" ] || die "no such file or folder: $SRC"

# Normalize to an absolute path so the "already in exports/" case-match
# below (line ~47) works regardless of whether the caller passed a relative
# or absolute path — a relative path pointing at an existing exports/<...>
# folder previously failed that string match and made a redundant second
# provenance copy of the same data instead of resuming from the first one.
if [ -d "$SRC" ]; then
    SRC="$(cd "$SRC" && pwd)"
else
    SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
fi

# --- 1. Land the raw export under exports/ (provenance) -------------------
mkdir -p "$EXPORTS"
if [[ "$SRC" == *.zip ]]; then
    stem="$(basename "$SRC" .zip)"
    RAW="$EXPORTS/${stem}_${TODAY}"
    [ -e "$RAW" ] && die "$RAW already exists — was this zip merged already?"
    unzip -q "$SRC" -d "$RAW"
    # Some zips wrap everything in a single top-level folder — flatten that.
    entries=("$RAW"/*)
    if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[0]}" ]; then
        mv "${entries[0]}"/* "$RAW"/ && rmdir "${entries[0]}"
    fi
else
    case "$SRC" in
        "$EXPORTS"/*) RAW="$SRC" ;;  # already in exports/ — use in place
        *)
            RAW="$EXPORTS/$(basename "$SRC")_${TODAY}"
            [ -e "$RAW" ] && die "$RAW already exists — was this folder merged already?"
            cp -R "$SRC" "$RAW"
            ;;
    esac
fi

# --- 2. Locate + validate the export's pieces -----------------------------
manifests=("$RAW"/hand_manifest_*.csv)
[ ${#manifests[@]} -eq 1 ] && [ -f "${manifests[0]}" ] \
    || die "expected exactly one hand_manifest_*.csv in $RAW, found: ${manifests[*]}"
MANIFEST="${manifests[0]}"
[ -d "$RAW/hand_images" ] || die "no hand_images/ folder in $RAW (folder must be named hand_images, underscore)"
[ -d "$RAW/imu" ] || echo "WARNING: no imu/ folder in $RAW — rows will train image-only (no --imu-seq windows)"

header="$(head -1 "$MANIFEST")"
if [ -f "$COMBINED" ]; then
    combined_header="$(head -1 "$COMBINED")"
    [ "$header" = "$combined_header" ] || die "manifest header does not match $COMBINED.
Export header:   $header
Combined header: $combined_header
(An old-schema combined file should be archived: mv it to hand_manifest_combined_legacy.csv and rerun.)"
else
    echo "$header" > "$COMBINED"
    echo "Created new $COMBINED"
fi

# Duplicate-merge guard: any image filename already present in the shared pool?
mkdir -p "$DEST/hand_images" "$DEST/imu"
dupes=0
for f in "$RAW/hand_images"/*.jpg; do
    [ -e "$f" ] || break
    [ -e "$DEST/hand_images/$(basename "$f")" ] && dupes=$((dupes + 1))
done
[ "$dupes" -eq 0 ] || die "$dupes image(s) from this export already exist in $DEST/hand_images — this export looks already merged. Nothing was copied."

# --- 3. Merge --------------------------------------------------------------
# `cp SRC/* DEST/` shell-globs every filename onto one command line, which
# blows past ARG_MAX on large exports (hit at ~16,900 files with 30fps
# capture); `cp -R SRC/. DEST/` copies directory CONTENTS as a single
# argument instead, sidestepping the glob entirely.
n_img="$(ls "$RAW/hand_images" | wc -l | tr -d ' ')"
cp -R "$RAW/hand_images/." "$DEST/hand_images/"
n_imu=0
if [ -d "$RAW/imu" ]; then
    n_imu="$(ls "$RAW/imu" | wc -l | tr -d ' ')"
    cp -R "$RAW/imu/." "$DEST/imu/"
fi
n_rows="$(tail -n +2 "$MANIFEST" | wc -l | tr -d ' ')"
tail -n +2 "$MANIFEST" >> "$COMBINED"

# --- 4. Report --------------------------------------------------------------
echo "Merged: $n_rows manifest rows, $n_img images, $n_imu IMU CSVs  (raw copy: $RAW)"
echo
echo "Combined dataset ($COMBINED):"
awk -F, 'NR>1 {p=$1"|"$2; label[$7]++; part[p]++} END {
    for (k in part) printf "  participant %-24s %5d frames\n", k, part[k];
    for (k in label) printf "  label       %-24s %5d frames\n", k, label[k];
    printf "  TOTAL       %29d frames\n", NR-1
}' "$COMBINED"
echo
echo "Train with:"
echo "  .venv-ml/bin/python scripts/train_hand_classifier.py \\"
echo "      Model-Training-Test/hand_manifest_combined.csv \\"
echo "      --images-root Model-Training-Test/ \\"
echo "      --out Model-Training-Test/models/ \\"
echo "      --imu-seq --imu-causal --imu-window 50 --epochs 30"
