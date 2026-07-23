"""Re-tune PosturePredictor's majority-vote window at the live 30 Hz cadence.

Why this exists: scripts/window_sweep.py swept vote windows over predictions
made once per labeled FRAME (~2 Hz, the old capture/tag cadence) and found
w=3 optimal. PosturePredictor now runs on a 30 Hz timer, where consecutive
50-sample causal windows overlap ~96% — votes are far more correlated, so
the 2 Hz optimum does not transfer.

This script simulates the live cadence directly: for each session IMU CSV it
takes prediction steps every 1/30 s across the span covered by that
session's labeled frames, builds the same causal 50x12 window the app
builds (imu_sequence.window_for_timestamp), batch-predicts with the
committed per-participant .keras models, then replays PosturePredictor's
EXACT smoothing semantics per vote window w:

    majority of the last w raw predictions; on a tie, keep the currently
    published label; publish the winner.

Votes never cross session (CSV) boundaries. Each step's ground truth is the
label of the nearest-in-time labeled frame in that session.

Cross-user rows are the deployment-realistic signal (the bundled
posture_imu.mlpackage is anonymous_-trained, so every other live user is a
"mock user" — see .claude/process/2026-07-15-cross-user-eval.md). ->self
rows run over each model's own full data, ~80% of which it trained on:
optimistic, shown for continuity with window_sweep.py only.

Usage (from repo root):
    venv/bin/python scripts/dense_window_sweep.py
"""
import json
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from hand_dataset import load_dataset_records  # noqa: E402
import imu_sequence  # noqa: E402

import keras  # noqa: E402

PREDICTION_HZ = 30.0
STEP_MS = 1000.0 / PREDICTION_HZ
SEQ_WINDOW = 50          # must match the committed models' --imu-window
WINDOW_SIZES = list(range(1, 16)) + [20, 25, 30, 45, 60, 90]
# Live requirement (POSTURE_DEMO B3): follow a grip change within ~1-2 s.
# At 30 Hz that caps the usable vote window at ~45 (1.5 s of votes).
MAX_LATENCY_W = 45


def slug(key: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", key)


def _parse_iso(s: str):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def build_dense_steps(records):
    """Per IMU CSV: dense 30 Hz prediction windows + nearest-frame labels.

    Returns (X, true_labels, group_slices, participant_of_group) where X is
    (N, SEQ_WINDOW, 12) float32, true_labels is list[str] parallel to X,
    group_slices is a list of (start, end) index ranges (one per session —
    votes must not cross them), participant_of_group parallel to
    group_slices.
    """
    groups = defaultdict(list)
    for i, rec in enumerate(records):
        if rec.get("imu_path"):
            groups[rec["imu_path"]].append(i)

    xs, labels, slices, participants = [], [], [], []
    skipped = 0
    for imu_path, idxs in sorted(groups.items()):
        series = imu_sequence.load_imu_series(imu_path)
        if series is None:
            skipped += 1
            continue

        # Same anchor as imu_sequence.build_sequence_dataset: t=0 at the
        # MIN captured_at_iso among ALL frames sharing this CSV.
        parsed = {i: _parse_iso(records[i].get("captured_at_iso", "")) for i in idxs}
        valid = [t for t in parsed.values() if t is not None]
        if not valid:
            skipped += 1
            continue
        anchor = min(valid)

        labeled = [
            (parsed[i], records[i]["label"]) for i in idxs
            if parsed[i] is not None and records[i]["label"] != "unknown"
        ]
        if not labeled:
            skipped += 1
            continue
        labeled.sort(key=lambda p: p[0])
        frame_t = np.array(
            [(t - anchor).total_seconds() * 1000.0 for t, _ in labeled])
        frame_lab = [lab for _, lab in labeled]

        start = len(labels)
        t = frame_t[0]
        t_end = frame_t[-1]
        step_ts = np.arange(t, t_end + STEP_MS / 2, STEP_MS)
        # Ground truth per step = label of the nearest labeled frame.
        nearest = np.searchsorted(frame_t, step_ts)
        for ti, ins in zip(step_ts, nearest):
            lo = max(ins - 1, 0)
            hi = min(ins, len(frame_t) - 1)
            j = lo if abs(frame_t[lo] - ti) <= abs(frame_t[hi] - ti) else hi
            xs.append(imu_sequence.window_for_timestamp(
                series, ti, window=SEQ_WINDOW, causal=True))
            labels.append(frame_lab[j])
        slices.append((start, len(labels)))
        participants.append(records[idxs[0]]["participant_key"])

    if skipped:
        print(f"note: {skipped} session group(s) skipped "
              f"(missing IMU CSV or no usable frames)")
    return np.asarray(xs, dtype=np.float32), labels, slices, participants


def replay_app_vote(preds, w, initial="unknown"):
    """PosturePredictor.decodePrediction's smoothing, verbatim in Python."""
    published = initial
    out = []
    recent = []
    counts = defaultdict(int)
    for p in preds:
        recent.append(p)
        counts[p] += 1
        if len(recent) > w:
            old = recent.pop(0)
            counts[old] -= 1
            if counts[old] == 0:
                del counts[old]
        max_count = max(counts.values())
        winners = [k for k, v in counts.items() if v == max_count]
        if len(winners) == 1:
            published = winners[0]
        elif published not in winners:
            published = p
        # else: tie including current published label -> keep it
        out.append(published)
    return out


def main() -> None:
    records = load_dataset_records(
        str(REPO / "Model-Training-Test/hand_manifest_combined.csv"),
        str(REPO / "Model-Training-Test"),
    )
    X, true_labels, group_slices, group_participant = build_dense_steps(records)
    n_sessions = len(group_slices)
    print(f"{X.shape[0]} dense steps ({PREDICTION_HZ:.0f} Hz) across "
          f"{n_sessions} sessions")

    participant_keys = sorted(set(group_participant))
    loaded = {}
    for key in participant_keys:
        mdir = REPO / "Model-Training-Test/models" / slug(key)
        model = keras.models.load_model(mdir / "hand_model.keras")
        with (mdir / "labels.json").open() as fh:
            classes = json.load(fh)
        loaded[key] = (model, classes)

    # Raw per-step argmax predictions, once per model over ALL steps.
    raw = {}
    for key, (model, classes) in loaded.items():
        probs = model.predict(X, verbose=0, batch_size=512)
        raw[key] = [classes[j] for j in np.asarray(probs).argmax(axis=1)]

    # (name, model_key, target participant, cross?) — cross-user rows are
    # the decision signal; ->self rows are train-contaminated context.
    combos = []
    for model_key in participant_keys:
        for target_key in participant_keys:
            kind = "self(train-seen)" if target_key == model_key else "cross"
            name = f"{slug(model_key)[:-1]}->{slug(target_key)[:-1]}({kind})"
            combos.append((name, model_key, target_key))

    header = (f"{'vote w':>7}{'latency@30Hz':>13}"
              + "".join(f"{n:>34}" for n, _, _ in combos))
    print(header)
    print("-" * len(header))

    cross_acc_by_w = {}
    cross_switch_by_w = {}
    for w in WINDOW_SIZES:
        cells = []
        cross_accs = []
        cross_switch_rates = []
        for _, model_key, target_key in combos:
            correct = total = switches = 0
            for (start, end), part in zip(group_slices, group_participant):
                if part != target_key:
                    continue
                voted = replay_app_vote(raw[model_key][start:end], w)
                truth = true_labels[start:end]
                correct += sum(v == t for v, t in zip(voted, truth))
                total += end - start
                switches += sum(a != b for a, b in zip(voted, voted[1:]))
            acc = correct / total if total else float("nan")
            cells.append(f"{acc:>34.4f}")
            if model_key != target_key:
                cross_accs.append(acc)
                # published-label changes per minute of live use — the
                # "label should hold steady" half of the B3 requirement,
                # which accuracy alone cannot see (a 4% error rate can be
                # one long burst or 30 Hz flicker).
                cross_switch_rates.append(
                    switches / (total / PREDICTION_HZ / 60.0))
        cross_acc_by_w[w] = float(np.mean(cross_accs))
        cross_switch_by_w[w] = float(np.mean(cross_switch_rates))
        print(f"{w:>7}{w / PREDICTION_HZ:>11.2f}s" + "".join(cells))

    print(f"\n{'vote w':>7}{'latency':>9}{'mean cross acc':>16}"
          f"{'cross switches/min':>20}")
    for w in WINDOW_SIZES:
        print(f"{w:>7}{w / PREDICTION_HZ:>7.2f}s{cross_acc_by_w[w]:>16.4f}"
              f"{cross_switch_by_w[w]:>20.1f}")

    # Recommendation: among windows meeting the <=1.5 s latency requirement
    # and within 0.002 of the best mean cross-user accuracy, take the one
    # with the steadiest published label (fewest switches/min); accuracy is
    # flat in w at this cadence, so stability is the deciding axis.
    eligible = [w for w in WINDOW_SIZES if w <= MAX_LATENCY_W]
    best = max(cross_acc_by_w[w] for w in eligible)
    near_best = [w for w in eligible if cross_acc_by_w[w] >= best - 0.002]
    rec = min(near_best, key=lambda w: (cross_switch_by_w[w], w))
    print(f"\nbest mean cross-user accuracy (w<={MAX_LATENCY_W}): "
          f"{best:.4f}")
    print(f"recommended voteWindowSize at {PREDICTION_HZ:.0f} Hz: {rec} "
          f"({rec / PREDICTION_HZ:.2f}s of votes, "
          f"{cross_switch_by_w[rec]:.1f} switches/min)")


if __name__ == "__main__":
    main()
