#!/usr/bin/env python3
"""Generate the compact, deterministic SymSpell English keyboard lexicon."""

from __future__ import annotations

import argparse
import hashlib
import urllib.request
from pathlib import Path


SYMSPELL_COMMIT = "c239062ae02961df18ab7da1671d01b4388204e0"
SYMSPELL_BLOB = "3682dedea3400a7f3ff34d521844c9c0c427ed74"
SOURCE_URL = (
    "https://raw.githubusercontent.com/wolfgarbe/SymSpell/"
    f"{SYMSPELL_COMMIT}/SymSpell/frequency_dictionary_en_82_765.txt"
)
SOURCE_SHA256 = "c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b"
MODEL_IDENTIFIER = "symspell-en-30k-c239062"
MAX_WORDS = 30_000
EXPLICIT_CORRECTIONS = {
    "helllo": "hello",
    "helo": "hello",
    "hte": "the",
    "teh": "the",
    "wierd": "weird",
}


def download_source() -> bytes:
    with urllib.request.urlopen(SOURCE_URL, timeout=60) as response:
        source = response.read()
    actual_hash = hashlib.sha256(source).hexdigest()
    if actual_hash != SOURCE_SHA256:
        raise RuntimeError(
            f"SymSpell source checksum changed: expected {SOURCE_SHA256}, got {actual_hash}"
        )
    return source


def parse_source(source: str) -> list[tuple[str, int]]:
    words: dict[str, tuple[str, int]] = {}
    for line_number, line in enumerate(source.splitlines(), start=1):
        try:
            word, raw_count = line.rsplit(maxsplit=1)
            count = int(raw_count)
        except ValueError as error:
            raise RuntimeError(f"Malformed source line {line_number}: {line!r}") from error
        if count <= 0:
            raise RuntimeError(f"Non-positive count on source line {line_number}")
        normalized = word.casefold()
        existing = words.get(normalized)
        if existing is None or count > existing[1]:
            words[normalized] = (word, count)

    ranked = sorted(words.values(), key=lambda item: (-item[1], item[0].casefold()))
    if len(ranked) < MAX_WORDS:
        raise RuntimeError(f"Expected at least {MAX_WORDS} unique words, got {len(ranked)}")
    return ranked[:MAX_WORDS]


def render_model(words: list[tuple[str, int]]) -> str:
    lines = [
        "# Adaptive Keyboard deterministic language model",
        f"# model_identifier={MODEL_IDENTIFIER}",
        f"# symspell_commit={SYMSPELL_COMMIT}",
        f"# symspell_blob={SYMSPELL_BLOB}",
        f"# source_sha256={SOURCE_SHA256}",
        f"# unigram_count={len(words)}",
        f"# explicit_correction_count={len(EXPLICIT_CORRECTIONS)}",
        "# W<TAB>corpus_count<TAB>word",
    ]
    lines.extend(f"W\t{count}\t{word}" for word, count in words)
    lines.extend(
        f"S\t{misspelling}\t{replacement}"
        for misspelling, replacement in sorted(EXPLICIT_CORRECTIONS.items())
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("TypingResearchShared/symspell_en_30k.tsv"),
    )
    args = parser.parse_args()

    source = download_source().decode("utf-8-sig")
    words = parse_source(source)
    rendered = render_model(words)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    output_hash = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    print(
        f"Wrote {args.output}: {len(words)} unigrams, "
        f"{len(EXPLICIT_CORRECTIONS)} explicit corrections, "
        f"sha256={output_hash}"
    )


if __name__ == "__main__":
    main()
