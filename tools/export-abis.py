#!/usr/bin/env python3
"""Export compiler ABIs after `forge build`; --check detects stale committed ABIs."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
for name in ("CatWars", "LaunchToken", "CatWarsEngine"):
    artifact = ROOT / "out" / f"{name}.sol" / f"{name}.json"
    destination = ROOT / "docs/abi" / f"{name}.json"
    content = json.dumps(json.loads(artifact.read_text())["abi"], indent=2) + "\n"
    if args.check:
        if not destination.exists() or destination.read_text() != content:
            raise SystemExit(f"Stale ABI: {destination.relative_to(ROOT)}")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
print("ABIs verified." if args.check else "ABIs exported.")
