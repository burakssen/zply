#!/usr/bin/env python3
"""Validate the Phase 12 M1 benchmark inventory; no Zig execution required."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = (
    "source", "step", "origin", "scope", "timed_boundary", "input",
    "execution", "consumer", "warmups", "measured_rounds", "statistic",
    "memory", "limitations",
)
SCOPES = {"micro", "pipeline", "end-to-end", "mixed"}


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    manifest_path = root / "benchmarks" / "audit.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return [f"cannot read {manifest_path}: {exc}"]

    if manifest.get("schema_version") != 1:
        errors.append("audit.json: unsupported schema_version (expected 1)")
    entries = manifest.get("benchmarks")
    if not isinstance(entries, list):
        return errors + ["audit.json: benchmarks must be a list"]

    try:
        build_source = (root / "build.zig").read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return errors + [f"cannot read build.zig: {exc}"]

    found: set[str] = set()
    steps: set[str] = set()
    for index, entry in enumerate(entries):
        prefix = f"benchmarks[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{prefix}: expected object")
            continue
        for field in REQUIRED:
            if field not in entry:
                errors.append(f"{prefix}: missing {field}")
            elif isinstance(entry[field], str) and not entry[field].strip():
                errors.append(f"{prefix}: empty {field}")

        source = entry.get("source")
        step = entry.get("step")
        scope = entry.get("scope")
        if scope not in SCOPES:
            errors.append(f"{prefix}: unknown scope {scope!r}")
        for field in ("warmups", "measured_rounds"):
            value = entry.get(field)
            if type(value) is not int or value < (1 if field == "measured_rounds" else 0):
                errors.append(f"{prefix}: invalid {field}: {value!r}")

        if isinstance(source, str):
            if source in found:
                errors.append(f"{prefix}: duplicate source {source}")
            found.add(source)
            if not re.fullmatch(r"benchmarks/[A-Za-z0-9_]+\.zig", source):
                errors.append(f"{prefix}: source must be a direct benchmarks/*.zig file: {source!r}")
            elif not (root / source).is_file():
                errors.append(f"{prefix}: missing source file: {source}")
            elif not re.search(r"\bpub\s+fn\s+main\s*\(", (root / source).read_text(encoding="utf-8")):
                errors.append(f"{prefix}: no benchmark main() in {source}")
            if isinstance(step, str) and f'"{source}"' not in build_source:
                errors.append(f"{prefix}: source not referenced by build.zig: {source}")

        if isinstance(step, str):
            if step in steps:
                errors.append(f"{prefix}: duplicate step {step}")
            steps.add(step)
            if not re.fullmatch(r"bench(?:-[a-z0-9]+)*", step):
                errors.append(f"{prefix}: invalid step name: {step!r}")
            elif f'b.step("{step}",' not in build_source:
                errors.append(f"{prefix}: build.zig has no b.step for {step}")

    source_files = {
        "benchmarks/" + file.name
        for file in (root / "benchmarks").glob("*.zig")
        if re.search(r"\bpub\s+fn\s+main\s*\(", file.read_text(encoding="utf-8"))
    }
    for missing in sorted(source_files - found):
        errors.append(f"missing benchmark audit entry: {missing}")
    for stale in sorted(found - source_files):
        errors.append(f"obsolete benchmark audit entry: {stale}")
    return errors


def main() -> int:
    errors = validate(ROOT)
    if errors:
        for message in errors:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1
    count = len(json.loads((ROOT / "benchmarks" / "audit.json").read_text())["benchmarks"])
    print(f"Phase 12 M1 audit: {count} benchmark entry points registered and documented")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
