#!/usr/bin/env python3
"""Compute active and committed-prefix CER/WER from FreeTypeRecorder logs.

This analysis treats the participant's final text as the reference, with two
important qualifications:

* A trailing word that was never committed by whitespace or punctuation is
  censored rather than guessed.
* A deliberately conservative spelling layer may normalize an otherwise
  uncorrected typo. Raw and spell-normalized metrics are both emitted, and
  every proposed/accepted spelling change is written to an audit CSV.

Active CER/WER compare every intermediate text state with the same-character-
length prefix of the final reference, including the unfinished word. Committed
CER/WER separately score only completed words. Text the participant has not
typed yet is never counted as a deletion. This is a retrospective editing-
trajectory metric, not a measurement of semantic intent.

The script never modifies source CSVs.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import string
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


DEFAULT_OUT_DIR = "results/prefix-error-metrics"
DEFAULT_DICTIONARY = "/usr/share/dict/words"
UNKNOWN_UNIT = 0xE000
WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")
BOUNDARY_RE = re.compile(r"[\s.,!?;:]$")
LETTERS = string.ascii_lowercase

# Domain-specific words that a general dictionary may reject but this project
# should never silently rewrite. Additional entries can be passed on the CLI.
DEFAULT_ALLOWLIST = {
    "app", "apps", "csv", "iphone", "ios", "imu", "gboard", "quicktype",
    "costco", "ups", "spiderman", "spider-man", "carbs",
}


@dataclass
class SessionInput:
    path: Path
    label: str
    rows: list[dict[str, str]]
    metadata: dict[str, object]
    snapshots: list[list[int]]
    replay_final_units: list[int]
    raw_final_text: str
    reference_source: str
    replay_unknown_units: int
    trailing_unknown_units: int
    assume_trailing_boundary: bool


@dataclass
class Reference:
    raw_text: str
    raw_words: list[str]
    normalized_text: str
    normalized_words: list[str]
    trailing_token_dropped: str
    accepted_corrections: int
    suggested_corrections: int


def _to_utf16_units(text: str) -> list[int]:
    data = text.encode("utf-16-le", errors="surrogatepass")
    return [int.from_bytes(data[index:index + 2], "little") for index in range(0, len(data), 2)]


def _from_utf16_units(units: Sequence[int], *, omit_unknown: bool = False) -> str:
    kept = [unit for unit in units if not (omit_unknown and unit == UNKNOWN_UNIT)]
    data = b"".join(unit.to_bytes(2, "little") for unit in kept)
    return data.decode("utf-16-le", errors="replace")


def _stable_text(units: Sequence[int]) -> str:
    """Return the known prefix before the first unlogged predictive unit."""
    try:
        end = units.index(UNKNOWN_UNIT)
    except ValueError:
        end = len(units)
    return _from_utf16_units(units[:end])


def replay_rows(rows: Sequence[dict[str, str]]) -> tuple[list[list[int]], list[int]]:
    """Replay UIKit edit ranges, retaining unknown system-generated units.

    Older exports sometimes report a resulting length jump while logging only
    the literal key that triggered an inline completion. Unknown UTF-16 units
    preserve that uncertainty instead of inventing text.
    """
    state: list[int] = []
    snapshots: list[list[int]] = []
    for row_number, row in enumerate(rows, start=2):
        try:
            start = int(row["range_start"])
            length = int(row["range_length"])
            expected_length = int(row["resulting_text_length"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"invalid edit range at CSV row {row_number}: {error}") from error

        replacement = _to_utf16_units(row.get("replacement_text", ""))
        if start > len(state):
            state.extend([UNKNOWN_UNIT] * (start - len(state)))
        state[start:start + length] = replacement

        insertion_end = start + len(replacement)
        delta = expected_length - len(state)
        if delta > 0:
            state[insertion_end:insertion_end] = [UNKNOWN_UNIT] * delta
        elif delta < 0:
            remove = -delta
            after = min(remove, max(0, len(state) - insertion_end))
            del state[insertion_end:insertion_end + after]
            remove -= after
            if remove:
                before_start = max(0, insertion_end - remove)
                del state[before_start:insertion_end]

        if len(state) != expected_length:
            raise ValueError(
                f"could not reconcile CSV row {row_number}: "
                f"replayed length {len(state)}, logged length {expected_length}"
            )
        snapshots.append(list(state))
    return snapshots, state


def resolve_inputs(inputs: Sequence[str]) -> list[Path]:
    resolved: set[Path] = set()
    for value in inputs:
        path = Path(value).expanduser().resolve()
        if path.is_file():
            if path.name.lower().endswith(".csv"):
                resolved.add(path)
            continue
        if path.is_dir():
            direct = path / "keystrokes.csv"
            if direct.is_file():
                resolved.add(direct)
            else:
                resolved.update(candidate for candidate in path.rglob("keystrokes.csv") if candidate.is_file())
    return sorted(resolved)


def _session_label(path: Path) -> str:
    if path.name == "keystrokes.csv":
        return path.parent.name
    stem = path.stem
    return stem[:-len("_keystrokes")] if stem.endswith("_keystrokes") else stem


def _infer_session_identity(label: str) -> tuple[int | None, str]:
    match = re.search(r",(\d+),(both|left|right)(?:_|$)", label, flags=re.IGNORECASE)
    if not match:
        return None, ""
    return int(match.group(1)), match.group(2).lower()


def load_session(path: Path) -> SessionInput:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    snapshots, replay_final = replay_rows(rows)

    metadata_path = path.parent / "session_meta.json"
    metadata: dict[str, object] = {}
    if metadata_path.is_file():
        with metadata_path.open(encoding="utf-8") as handle:
            metadata = json.load(handle)

    label = _session_label(path)
    inferred_number, inferred_hand = _infer_session_identity(label)
    if inferred_number is not None:
        metadata.setdefault("sessionNumber", inferred_number)
    if inferred_hand:
        metadata.setdefault("hand", inferred_hand)

    final_text_path = path.parent / "final_text.txt"
    unknown_count = replay_final.count(UNKNOWN_UNIT)
    trailing_unknown = 0
    for unit in reversed(replay_final):
        if unit != UNKNOWN_UNIT:
            break
        trailing_unknown += 1

    if final_text_path.is_file():
        raw_final = final_text_path.read_text(encoding="utf-8")
        source = "final_text.txt"
        assume_boundary = bool(raw_final and BOUNDARY_RE.search(raw_final))
    else:
        raw_final = _from_utf16_units(replay_final, omit_unknown=True)
        source = "replayed_keystrokes_csv"
        # A trailing unlogged unit is commonly the space appended by inline
        # prediction. Preserve the explicitly typed last word in that case.
        assume_boundary = bool(trailing_unknown) or bool(raw_final and BOUNDARY_RE.search(raw_final))

    return SessionInput(
        path=path,
        label=label,
        rows=rows,
        metadata=metadata,
        snapshots=snapshots,
        replay_final_units=replay_final,
        raw_final_text=raw_final,
        reference_source=source,
        replay_unknown_units=unknown_count,
        trailing_unknown_units=trailing_unknown,
        assume_trailing_boundary=assume_boundary,
    )


def _normalized_word(word: str) -> str:
    return word.replace("’", "'").casefold()


def _word_matches(text: str) -> list[re.Match[str]]:
    return list(WORD_RE.finditer(text))


def committed_reference_text(text: str, *, assume_trailing_boundary: bool = False) -> tuple[str, str]:
    matches = _word_matches(text)
    if not matches:
        return "", ""
    last = matches[-1]
    unfinished = last.end() == len(text) and not assume_trailing_boundary
    if unfinished:
        return text[:last.start()].rstrip(), last.group(0)
    return text.rstrip(), ""


def committed_words(text: str, *, assume_trailing_boundary: bool = False) -> list[str]:
    committed_text, _ = committed_reference_text(
        text, assume_trailing_boundary=assume_trailing_boundary
    )
    return [_normalized_word(match.group(0)) for match in _word_matches(committed_text)]


def _damerau_distance_one_candidates(word: str) -> set[str]:
    """Generate lowercase strings one basic keyboard edit from ``word``."""
    splits = [(word[:index], word[index:]) for index in range(len(word) + 1)]
    candidates = {left + right[1:] for left, right in splits if right}
    candidates.update(
        left + right[1] + right[0] + right[2:]
        for left, right in splits
        if len(right) > 1
    )
    candidates.update(
        left + letter + right[1:]
        for left, right in splits
        if right
        for letter in LETTERS
        if letter != right[0]
    )
    candidates.update(left + letter + right for left, right in splits for letter in LETTERS)
    candidates.discard(word)
    return candidates


def _recognized_inflection(word: str, lexicon: set[str]) -> bool:
    bases: set[str] = set()
    if word.endswith("s") and len(word) > 3:
        bases.add(word[:-1])
    if word.endswith("ies") and len(word) > 4:
        bases.add(word[:-3] + "y")
    if word.endswith("es") and len(word) > 4:
        bases.update({word[:-2], word[:-1]})
    if word.endswith("ed") and len(word) > 4:
        base = word[:-2]
        bases.update({base, word[:-1]})
        if len(base) > 3 and base[-1:] == base[-2:-1]:
            bases.add(base[:-1])
    if word.endswith("ing") and len(word) > 5:
        base = word[:-3]
        bases.update({base, base + "e"})
        if len(base) > 3 and base[-1:] == base[-2:-1]:
            bases.add(base[:-1])
    return any(len(base) >= 3 and base in lexicon for base in bases)


def _load_explicit_corrections(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    result: dict[str, str] = {}
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        required = {"original", "replacement"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError("corrections CSV must contain original,replacement columns")
        for row in reader:
            original = _normalized_word(row["original"].strip())
            replacement = _normalized_word(row["replacement"].strip())
            if original and replacement and " " not in replacement:
                result[original] = replacement
    return result


class ConservativeSpellChecker:
    """Context-free spelling suggestions with a strong abstention default."""

    def __init__(
        self,
        lexicon: Iterable[str],
        evidence: Counter[str],
        *,
        explicit: dict[str, str] | None = None,
        allowlist: Iterable[str] = (),
    ) -> None:
        self.lexicon = {_normalized_word(word.strip()) for word in lexicon if word.strip()}
        self.evidence = evidence
        self.explicit = explicit or {}
        self.allowlist = {_normalized_word(word) for word in allowlist} | DEFAULT_ALLOWLIST

    def decide(self, surface: str) -> tuple[str, str, list[str], str]:
        word = _normalized_word(surface)
        if word in self.explicit:
            replacement = self.explicit[word]
            return replacement, "accepted_explicit", [replacement], "reviewed correction map"
        if word in self.allowlist or word in self.lexicon:
            return word, "unchanged", [], "recognized or allowlisted"
        # System dictionaries are often lemma-heavy. Never rewrite a valid
        # plural, past tense, or participle merely because the lemma has
        # stronger corpus evidence.
        if _recognized_inflection(word, self.lexicon):
            return word, "preserved", [], "recognized regular inflection"
        if (
            len(word) < 3
            or any(character.isdigit() for character in word)
            or "'" in word
            or "-" in word
            or (surface[:1].isupper() and not surface.isupper())
            or surface.isupper()
        ):
            return word, "preserved", [], "name/acronym/compound/short token guard"

        candidates = _damerau_distance_one_candidates(word) & self.lexicon
        ranked = sorted(candidates, key=lambda candidate: (-self.evidence[candidate], candidate))
        if not ranked:
            return word, "preserved", [], "no one-edit dictionary candidate"

        top = ranked[0]
        top_score = self.evidence[top]
        second_score = self.evidence[ranked[1]] if len(ranked) > 1 else 0
        if top_score >= 3 and top_score > 2 * second_score:
            return top, "accepted_corpus", ranked[:5], f"local evidence {top_score} vs {second_score}"
        return word, "suggested", ranked[:5], f"insufficient local evidence {top_score} vs {second_score}"


def _match_case(original: str, replacement: str) -> str:
    if original.isupper():
        return replacement.upper()
    if original[:1].isupper():
        return replacement[:1].upper() + replacement[1:]
    return replacement


def spell_normalize(
    session: SessionInput,
    raw_reference: str,
    checker: ConservativeSpellChecker,
) -> tuple[str, list[dict[str, object]], int, int]:
    pieces: list[str] = []
    cursor = 0
    audit: list[dict[str, object]] = []
    accepted = 0
    suggested = 0
    for match in _word_matches(raw_reference):
        surface = match.group(0)
        replacement, status, candidates, reason = checker.decide(surface)
        pieces.append(raw_reference[cursor:match.start()])
        rendered = _match_case(surface, replacement)
        pieces.append(rendered if status.startswith("accepted") else surface)
        cursor = match.end()
        if status != "unchanged":
            audit.append({
                "session": session.label,
                "source_csv": str(session.path),
                "token": surface,
                "replacement": rendered if status.startswith("accepted") else "",
                "status": status,
                "candidates": "|".join(candidates),
                "reason": reason,
                "character_start": match.start(),
            })
        accepted += int(status.startswith("accepted"))
        suggested += int(status == "suggested")
    pieces.append(raw_reference[cursor:])
    return "".join(pieces), audit, accepted, suggested


def levenshtein_counts(reference: Sequence[str], hypothesis: Sequence[str]) -> tuple[int, int, int]:
    """Return substitutions, deletions, insertions for ref -> hypothesis."""
    rows = len(reference) + 1
    cols = len(hypothesis) + 1
    distance = [[0] * cols for _ in range(rows)]
    ops = [[(0, 0, 0)] * cols for _ in range(rows)]
    for row in range(1, rows):
        distance[row][0] = row
        ops[row][0] = (0, row, 0)
    for col in range(1, cols):
        distance[0][col] = col
        ops[0][col] = (0, 0, col)

    for row in range(1, rows):
        for col in range(1, cols):
            if reference[row - 1] == hypothesis[col - 1]:
                distance[row][col] = distance[row - 1][col - 1]
                ops[row][col] = ops[row - 1][col - 1]
                continue
            sub = ops[row - 1][col - 1]
            delete = ops[row - 1][col]
            insert = ops[row][col - 1]
            choices = [
                (distance[row - 1][col - 1] + 1, (sub[0] + 1, sub[1], sub[2]), 0),
                (distance[row - 1][col] + 1, (delete[0], delete[1] + 1, delete[2]), 1),
                (distance[row][col - 1] + 1, (insert[0], insert[1], insert[2] + 1), 2),
            ]
            best_distance, best_ops, _ = min(choices, key=lambda item: (item[0], item[2]))
            distance[row][col] = best_distance
            ops[row][col] = best_ops
    return ops[-1][-1]


def _metric_fields(prefix: str, reference: Sequence[str], hypothesis: Sequence[str]) -> dict[str, object]:
    substitutions, deletions, insertions = levenshtein_counts(reference, hypothesis)
    errors = substitutions + deletions + insertions
    denominator = len(reference)
    return {
        f"{prefix}_substitutions": substitutions,
        f"{prefix}_deletions": deletions,
        f"{prefix}_insertions": insertions,
        f"{prefix}_errors": errors,
        f"{prefix}_denominator": denominator,
        prefix: "" if denominator == 0 else errors / denominator,
    }


def _score_snapshot(current_text: str, reference_words: Sequence[str], prefix: str) -> dict[str, object]:
    current_words = committed_words(current_text)
    reference_count = min(len(current_words), len(reference_words))
    reference_prefix = list(reference_words[:reference_count])
    current_chars = list(" ".join(current_words))
    reference_chars = list(" ".join(reference_prefix))
    result: dict[str, object] = {
        f"{prefix}_reference_prefix": " ".join(reference_prefix),
        f"{prefix}_reference_words": reference_count,
    }
    result.update(_metric_fields(f"{prefix}_cer", reference_chars, current_chars))
    result.update(_metric_fields(f"{prefix}_wer", reference_prefix, current_words))
    return result


def _normalized_active_text(text: str) -> str:
    """Normalize case/apostrophes while retaining spaces and punctuation."""
    return (
        text.replace("\r\n", "\n")
        .replace("\r", "\n")
        .replace("’", "'")
        .casefold()
        .rstrip()
    )


def _score_active_snapshot(
    current_text: str,
    reference_text: str,
    prefix: str,
    *,
    censor_suffix_beyond_reference: bool = False,
) -> dict[str, object]:
    """Score every visible character against the same-length final prefix."""
    current = _normalized_active_text(current_text)
    reference = _normalized_active_text(reference_text)
    if censor_suffix_beyond_reference and len(current) > len(reference):
        current = current[:len(reference)]
    reference_prefix = reference[:min(len(current), len(reference))]
    result: dict[str, object] = {
        f"{prefix}_current_text": current,
        f"{prefix}_reference_prefix": reference_prefix,
        f"{prefix}_reference_characters": len(reference_prefix),
    }
    result.update(_metric_fields(f"{prefix}_cer", list(reference_prefix), list(current)))
    current_words = [_normalized_word(match.group(0)) for match in _word_matches(current)]
    reference_words = [
        _normalized_word(match.group(0)) for match in _word_matches(reference_prefix)
    ]
    result.update(_metric_fields(f"{prefix}_wer", reference_words, current_words))
    return result


def _load_dictionary(path: str) -> list[str]:
    dictionary_path = Path(path)
    if not dictionary_path.is_file():
        raise FileNotFoundError(f"dictionary not found: {dictionary_path}")
    return dictionary_path.read_text(encoding="utf-8", errors="ignore").splitlines()


def _build_evidence(sessions: Sequence[SessionInput], raw_references: dict[str, str], lexicon: set[str]) -> Counter[str]:
    evidence: Counter[str] = Counter()
    for text in raw_references.values():
        for match in _word_matches(text):
            word = _normalized_word(match.group(0))
            if word in lexicon:
                evidence[word] += 1
    for session in sessions:
        for row in session.rows:
            if row.get("event_type") not in {"replace", "paste"}:
                continue
            replacement_matches = _word_matches(row.get("replacement_text", ""))
            replaced_matches = _word_matches(row.get("replaced_text", ""))
            if len(replacement_matches) == len(replaced_matches) == 1:
                replacement = _normalized_word(replacement_matches[0].group(0))
                if replacement in lexicon:
                    evidence[replacement] += 3
    return evidence


def _write_csv(path: Path, rows: Sequence[dict[str, object]], fieldnames: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _numeric(value: object) -> float:
    if value in {"", None}:
        return 0.0
    return float(value)


def _weighted_mean(
    rows: Sequence[dict[str, object]],
    value_field: str,
    weight_field: str,
) -> float:
    total_weight = sum(_numeric(row.get(weight_field)) for row in rows)
    if not total_weight:
        return 0.0
    return sum(
        _numeric(row.get(value_field)) * _numeric(row.get(weight_field))
        for row in rows
    ) / total_weight


def _markdown_cell(value: object) -> str:
    return str(value if value not in {"", None} else "—").replace("\\", "\\\\").replace("|", "\\|")


def _percent(value: object) -> str:
    if value in {"", None}:
        return "—"
    return f"{float(value):.4%}"


def _write_markdown_summary(
    path: Path,
    summaries: Sequence[dict[str, object]],
    audit: Sequence[dict[str, object]],
) -> None:
    active_timestamps = sum(int(_numeric(row.get("active_scored_timestamps"))) for row in summaries)
    active_divergent = sum(int(_numeric(row.get("active_divergent_timestamps"))) for row in summaries)
    introduced_events = sum(int(_numeric(row.get("introduced_error_events"))) for row in summaries)
    introduced_units = sum(int(_numeric(row.get("introduced_error_units"))) for row in summaries)
    corrected_events = sum(int(_numeric(row.get("corrected_error_events"))) for row in summaries)
    corrected_units = sum(int(_numeric(row.get("corrected_error_units"))) for row in summaries)
    accepted_spelling = sum(1 for row in audit if str(row.get("status", "")).startswith("accepted_"))
    suggested_spelling = sum(1 for row in audit if row.get("status") == "suggested")

    lines = [
        "# CER/WER Metrics Summary",
        "",
        "## Overall",
        "",
        f"- Sessions analyzed: **{len(summaries)}**",
        f"- Active scored timestamps: **{active_timestamps}**",
        f"- Active divergent timestamps: **{active_divergent}**",
        f"- Event-weighted active CER: **{_weighted_mean(summaries, 'mean_raw_active_cer', 'active_scored_timestamps'):.4%}**",
        f"- Event-weighted active WER: **{_weighted_mean(summaries, 'mean_raw_active_wer', 'active_scored_timestamps'):.4%}**",
        f"- Error-introducing events: **{introduced_events}** ({introduced_units} error units)",
        f"- Error-correcting events: **{corrected_events}** ({corrected_units} error units)",
        f"- Spell-check changes accepted: **{accepted_spelling}**; suggestions preserved for review: **{suggested_spelling}**",
        "",
        "## Per-session metrics",
        "",
        "| Session | Hand | Events | Active divergent | Error-introducing events | Mean active CER | Mean active WER |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summaries:
        lines.append("| " + " | ".join([
            _markdown_cell(row.get("session")),
            _markdown_cell(row.get("hand")),
            _markdown_cell(row.get("event_rows")),
            _markdown_cell(row.get("active_divergent_timestamps")),
            _markdown_cell(row.get("introduced_error_events")),
            _percent(row.get("mean_raw_active_cer")),
            _percent(row.get("mean_raw_active_wer")),
        ]) + " |")
    lines += [
        "",
        "## Method",
        "",
        "The final reconstructed user input is treated as ground truth. After every edit, active CER compares characters and active WER compares word tokens against the same-character-length prefix of the final text, so future text and correctly typed partial words are not penalized.",
        "",
        "The spell-check layer is conservative and does not make grammatical corrections. Intentional revisions may still appear as divergences because this analysis assumes the final response is correct.",
        "",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def analyze(
    sessions: Sequence[SessionInput],
    *,
    dictionary: Sequence[str],
    explicit_corrections: dict[str, str],
    allowlist: Iterable[str],
) -> tuple[list[dict[str, object]], list[dict[str, object]], list[dict[str, object]]]:
    raw_references: dict[str, str] = {}
    dropped_tokens: dict[str, str] = {}
    for session in sessions:
        raw_reference, dropped = committed_reference_text(
            session.raw_final_text,
            assume_trailing_boundary=session.assume_trailing_boundary,
        )
        raw_references[session.label] = raw_reference
        dropped_tokens[session.label] = dropped

    lexicon = {_normalized_word(word) for word in dictionary if word.strip()}
    evidence = _build_evidence(sessions, raw_references, lexicon)
    checker = ConservativeSpellChecker(
        lexicon,
        evidence,
        explicit=explicit_corrections,
        allowlist=allowlist,
    )

    references: dict[str, Reference] = {}
    spelling_audit: list[dict[str, object]] = []
    for session in sessions:
        raw_text = raw_references[session.label]
        normalized_text, audit, accepted, suggested = spell_normalize(session, raw_text, checker)
        spelling_audit.extend(audit)
        references[session.label] = Reference(
            raw_text=raw_text,
            raw_words=committed_words(raw_text, assume_trailing_boundary=True),
            normalized_text=normalized_text,
            normalized_words=committed_words(normalized_text, assume_trailing_boundary=True),
            trailing_token_dropped=dropped_tokens[session.label],
            accepted_corrections=accepted,
            suggested_corrections=suggested,
        )

    timestamp_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []
    for session in sessions:
        reference = references[session.label]
        raw_cers: list[float] = []
        normalized_cers: list[float] = []
        raw_wers: list[float] = []
        normalized_wers: list[float] = []
        raw_active_cers: list[float] = []
        normalized_active_cers: list[float] = []
        raw_active_wers: list[float] = []
        normalized_active_wers: list[float] = []
        divergent = 0
        active_divergent = 0
        introduced_error_events = 0
        introduced_error_units = 0
        corrected_error_events = 0
        corrected_error_units = 0
        previous_active_errors = 0
        for index, (row, units) in enumerate(zip(session.rows, session.snapshots), start=1):
            current = _stable_text(units)
            metric_row: dict[str, object] = {
                "session": session.label,
                "session_number": session.metadata.get("sessionNumber", ""),
                "hand": session.metadata.get("hand", ""),
                "event_index": index,
                "t_ms": row.get("t_ms", ""),
                "event_type": row.get("event_type", ""),
                "current_stable_text": current,
                "current_committed_text": " ".join(committed_words(current)),
                "unlogged_predictive_units": units.count(UNKNOWN_UNIT),
            }
            raw_score = _score_snapshot(current, reference.raw_words, "raw")
            if reference.normalized_words == reference.raw_words:
                normalized_score = {
                    key.replace("raw_", "spell_", 1): value
                    for key, value in raw_score.items()
                }
            else:
                normalized_score = _score_snapshot(current, reference.normalized_words, "spell")
            censor_trailing_suffix = bool(reference.trailing_token_dropped)
            raw_active_score = _score_active_snapshot(
                current,
                reference.raw_text,
                "raw_active",
                censor_suffix_beyond_reference=censor_trailing_suffix,
            )
            if reference.normalized_text == reference.raw_text:
                normalized_active_score = {
                    key.replace("raw_active_", "spell_active_", 1): value
                    for key, value in raw_active_score.items()
                }
            else:
                normalized_active_score = _score_active_snapshot(
                    current,
                    reference.normalized_text,
                    "spell_active",
                    censor_suffix_beyond_reference=censor_trailing_suffix,
                )
            metric_row.update(raw_score)
            metric_row.update(normalized_score)
            metric_row.update(raw_active_score)
            metric_row.update(normalized_active_score)

            active_errors = int(metric_row["raw_active_cer_errors"])
            error_delta = active_errors - previous_active_errors
            metric_row["raw_active_error_delta"] = error_delta
            if error_delta > 0:
                metric_row["raw_active_event_outcome"] = "introduced_error"
                introduced_error_events += 1
                introduced_error_units += error_delta
            elif error_delta < 0:
                metric_row["raw_active_event_outcome"] = "corrected_error"
                corrected_error_events += 1
                corrected_error_units += -error_delta
            else:
                metric_row["raw_active_event_outcome"] = "no_error_change"
            previous_active_errors = active_errors
            timestamp_rows.append(metric_row)

            for key, target in [
                ("raw_cer", raw_cers), ("spell_cer", normalized_cers),
                ("raw_wer", raw_wers), ("spell_wer", normalized_wers),
            ]:
                value = metric_row[key]
                if value != "":
                    target.append(float(value))
            for key, target in [
                ("raw_active_cer", raw_active_cers),
                ("spell_active_cer", normalized_active_cers),
                ("raw_active_wer", raw_active_wers),
                ("spell_active_wer", normalized_active_wers),
            ]:
                value = metric_row[key]
                if value != "":
                    target.append(float(value))
            if metric_row["raw_cer_errors"] or metric_row["raw_wer_errors"]:
                divergent += 1
            if metric_row["raw_active_cer_errors"]:
                active_divergent += 1

        final = timestamp_rows[-1] if session.rows else {}
        summary_rows.append({
            "session": session.label,
            "source_csv": str(session.path),
            "session_number": session.metadata.get("sessionNumber", ""),
            "hand": session.metadata.get("hand", ""),
            "prompt": session.metadata.get("prompt", ""),
            "reference_source": session.reference_source,
            "raw_final_text": session.raw_final_text,
            "raw_committed_reference": reference.raw_text,
            "spell_normalized_reference": reference.normalized_text,
            "trailing_token_dropped": reference.trailing_token_dropped,
            "replay_unknown_units": session.replay_unknown_units,
            "trailing_unknown_units": session.trailing_unknown_units,
            "accepted_spelling_corrections": reference.accepted_corrections,
            "suggested_spelling_corrections": reference.suggested_corrections,
            "event_rows": len(session.rows),
            "scored_timestamps": len(raw_cers),
            "divergent_timestamps": divergent,
            "active_scored_timestamps": len(raw_active_cers),
            "active_divergent_timestamps": active_divergent,
            "introduced_error_events": introduced_error_events,
            "introduced_error_units": introduced_error_units,
            "corrected_error_events": corrected_error_events,
            "corrected_error_units": corrected_error_units,
            "mean_raw_prefix_cer": sum(raw_cers) / len(raw_cers) if raw_cers else "",
            "mean_raw_prefix_wer": sum(raw_wers) / len(raw_wers) if raw_wers else "",
            "mean_spell_prefix_cer": sum(normalized_cers) / len(normalized_cers) if normalized_cers else "",
            "mean_spell_prefix_wer": sum(normalized_wers) / len(normalized_wers) if normalized_wers else "",
            "mean_raw_active_cer": sum(raw_active_cers) / len(raw_active_cers) if raw_active_cers else "",
            "mean_spell_active_cer": sum(normalized_active_cers) / len(normalized_active_cers) if normalized_active_cers else "",
            "mean_raw_active_wer": sum(raw_active_wers) / len(raw_active_wers) if raw_active_wers else "",
            "mean_spell_active_wer": sum(normalized_active_wers) / len(normalized_active_wers) if normalized_active_wers else "",
            "final_raw_cer": final.get("raw_cer", ""),
            "final_raw_wer": final.get("raw_wer", ""),
            "final_spell_cer": final.get("spell_cer", ""),
            "final_spell_wer": final.get("spell_wer", ""),
            "final_raw_active_cer": final.get("raw_active_cer", ""),
            "final_spell_active_cer": final.get("spell_active_cer", ""),
            "final_raw_active_wer": final.get("raw_active_wer", ""),
            "final_spell_active_wer": final.get("spell_active_wer", ""),
        })
    return summary_rows, timestamp_rows, spelling_audit


SUMMARY_FIELDS = [
    "session", "source_csv", "session_number", "hand", "prompt", "reference_source",
    "raw_final_text", "raw_committed_reference", "spell_normalized_reference",
    "trailing_token_dropped", "replay_unknown_units", "trailing_unknown_units",
    "accepted_spelling_corrections", "suggested_spelling_corrections", "event_rows",
    "scored_timestamps", "divergent_timestamps", "active_scored_timestamps",
    "active_divergent_timestamps", "introduced_error_events", "introduced_error_units",
    "corrected_error_events", "corrected_error_units", "mean_raw_prefix_cer",
    "mean_raw_prefix_wer", "mean_spell_prefix_cer", "mean_spell_prefix_wer",
    "mean_raw_active_cer", "mean_spell_active_cer", "final_raw_cer", "final_raw_wer",
    "final_spell_cer", "final_spell_wer", "final_raw_active_cer", "final_spell_active_cer",
    "mean_raw_active_wer", "mean_spell_active_wer", "final_raw_active_wer",
    "final_spell_active_wer",
]

TIMESTAMP_FIELDS = [
    "session", "session_number", "hand", "event_index", "t_ms", "event_type",
    "current_stable_text", "current_committed_text", "unlogged_predictive_units",
    "raw_reference_prefix", "raw_reference_words",
    "raw_cer_substitutions", "raw_cer_deletions", "raw_cer_insertions",
    "raw_cer_errors", "raw_cer_denominator", "raw_cer",
    "raw_wer_substitutions", "raw_wer_deletions", "raw_wer_insertions",
    "raw_wer_errors", "raw_wer_denominator", "raw_wer",
    "spell_reference_prefix", "spell_reference_words",
    "spell_cer_substitutions", "spell_cer_deletions", "spell_cer_insertions",
    "spell_cer_errors", "spell_cer_denominator", "spell_cer",
    "spell_wer_substitutions", "spell_wer_deletions", "spell_wer_insertions",
    "spell_wer_errors", "spell_wer_denominator", "spell_wer",
    "raw_active_current_text", "raw_active_reference_prefix", "raw_active_reference_characters",
    "raw_active_cer_substitutions", "raw_active_cer_deletions", "raw_active_cer_insertions",
    "raw_active_cer_errors", "raw_active_cer_denominator", "raw_active_cer",
    "spell_active_current_text", "spell_active_reference_prefix", "spell_active_reference_characters",
    "spell_active_cer_substitutions", "spell_active_cer_deletions", "spell_active_cer_insertions",
    "spell_active_cer_errors", "spell_active_cer_denominator", "spell_active_cer",
    "raw_active_error_delta", "raw_active_event_outcome",
    "raw_active_wer_substitutions", "raw_active_wer_deletions", "raw_active_wer_insertions",
    "raw_active_wer_errors", "raw_active_wer_denominator", "raw_active_wer",
    "spell_active_wer_substitutions", "spell_active_wer_deletions", "spell_active_wer_insertions",
    "spell_active_wer_errors", "spell_active_wer_denominator", "spell_active_wer",
]

AUDIT_FIELDS = [
    "session", "source_csv", "token", "replacement", "status", "candidates",
    "reason", "character_start",
]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", help="keystrokes.csv, session directory, or export root")
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR, help="output directory")
    parser.add_argument("--dictionary", default=DEFAULT_DICTIONARY, help="newline-delimited dictionary")
    parser.add_argument(
        "--corrections-csv",
        help="reviewed original,replacement pairs; these are the only unconditional corrections",
    )
    parser.add_argument("--allow-word", action="append", default=[], help="word that must never be corrected")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    paths = resolve_inputs(args.inputs)
    if not paths:
        raise SystemExit("no keystrokes.csv files found")
    sessions = [load_session(path) for path in paths]
    sessions.sort(key=lambda session: (
        int(session.metadata.get("sessionNumber", 10**9)),
        session.label,
    ))
    dictionary = _load_dictionary(args.dictionary)
    explicit = _load_explicit_corrections(args.corrections_csv)
    summaries, timestamps, audit = analyze(
        sessions,
        dictionary=dictionary,
        explicit_corrections=explicit,
        allowlist=args.allow_word,
    )

    output = Path(args.out_dir).expanduser().resolve()
    _write_csv(output / "session_summary.csv", summaries, SUMMARY_FIELDS)
    _write_csv(output / "timestamp_metrics.csv", timestamps, TIMESTAMP_FIELDS)
    _write_csv(output / "spelling_audit.csv", audit, AUDIT_FIELDS)
    _write_markdown_summary(output / "metrics_summary.md", summaries, audit)
    print(f"Analyzed {len(sessions)} sessions ({len(timestamps)} events)")
    print(output / "session_summary.csv")
    print(output / "timestamp_metrics.csv")
    print(output / "spelling_audit.csv")
    print(output / "metrics_summary.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
