#!/usr/bin/env python3
"""
Run reproducible posture/adaptation ablation preset sweeps.

Examples:
  python3 scripts/ablation_presets.py list
  python3 scripts/ablation_presets.py posture --manifest <manifest.csv> --images-root <root> --out-dir results/ablations/posture --execute
  python3 scripts/ablation_presets.py adaptation --cleaned-csv <cleaned.csv> --out-dir results/ablations/adaptation --execute
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PRESET_FILE = Path(__file__).with_name("ablation_presets.json")


@dataclass(frozen=True)
class PresetCommand:
    id: str
    description: str
    command_template: str


def load_presets() -> dict[str, list[PresetCommand]]:
    data = json.loads(PRESET_FILE.read_text(encoding="utf-8"))
    out: dict[str, list[PresetCommand]] = {}
    for bucket, rows in data.items():
        out[bucket] = [
            PresetCommand(
                id=row["id"],
                description=row["description"],
                command_template=row["command_template"],
            )
            for row in rows
        ]
    return out


def render_command(template: str, values: dict[str, str]) -> str:
    result = template
    for key, value in values.items():
        result = result.replace("{" + key + "}", shlex.quote(value))
    return result


def run_commands(commands: Iterable[str], execute: bool) -> None:
    for index, cmd in enumerate(commands, start=1):
        print(f"[{index}] {cmd}")
        if not execute:
            continue
        subprocess.run(cmd, shell=True, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)

    sub.add_parser("list", help="List available preset groups and commands")

    posture = sub.add_parser("posture", help="Run posture-model ablation presets")
    posture.add_argument("--manifest", required=True)
    posture.add_argument("--images-root", required=True)
    posture.add_argument("--out-dir", required=True)
    posture.add_argument("--execute", action="store_true")

    adaptation = sub.add_parser("adaptation", help="Run keyboard-adaptation ablation presets")
    adaptation.add_argument("--cleaned-csv", required=True)
    adaptation.add_argument("--out-dir", required=True)
    adaptation.add_argument("--execute", action="store_true")

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    presets = load_presets()

    if args.mode == "list":
        for bucket, rows in presets.items():
            print(f"\n[{bucket}]")
            for row in rows:
                print(f"- {row.id}: {row.description}")
        return

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.mode == "posture":
        values = {
            "manifest": str(Path(args.manifest).resolve()),
            "images_root": str(Path(args.images_root).resolve()),
            "out_dir": str(out_dir.resolve()),
        }
        cmds = [render_command(row.command_template, values) for row in presets["posture"]]
        run_commands(cmds, execute=args.execute)
        return

    if args.mode == "adaptation":
        values = {
            "cleaned_csv": str(Path(args.cleaned_csv).resolve()),
            "out_dir": str(out_dir.resolve()),
        }
        cmds = [render_command(row.command_template, values) for row in presets["adaptation"]]
        run_commands(cmds, execute=args.execute)
        return


if __name__ == "__main__":
    main()
