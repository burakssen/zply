#!/usr/bin/env python3
"""Run and record a reproducible Phase 12 benchmark capture.

Usage:
  python3 scripts/capture_phase12.py results/candidate.csv -- \
    zig build bench-phase12 -Doptimize=ReleaseFast -- --consumer=minimal

The benchmark writes its CSV stream to stderr. This wrapper preserves that raw
stream, validates it, and writes a neighbouring JSON environment manifest.
It deliberately does not fabricate a baseline or silently retry measurements.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from check_phase12_capture import parse_text, validate_text


def command_output(command: list[str]) -> str | None:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def cpu_model() -> str:
    if sys.platform == "darwin":
        return command_output(["sysctl", "-n", "machdep.cpu.brand_string"]) or \
            command_output(["sysctl", "-n", "hw.model"]) or "unknown"
    if sys.platform.startswith("linux"):
        try:
            for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
                if line.startswith(("model name", "Hardware")) and ":" in line:
                    return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return platform.processor() or "unknown"


def integer_command(command: list[str]) -> int | None:
    value = command_output(command)
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def core_configuration() -> dict[str, int | None]:
    physical = None
    if sys.platform == "darwin":
        physical = integer_command(["sysctl", "-n", "hw.physicalcpu"])
    return {"logical": os.cpu_count(), "physical": physical}


def total_memory_bytes() -> int | None:
    if sys.platform == "darwin":
        return integer_command(["sysctl", "-n", "hw.memsize"])
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (AttributeError, OSError, ValueError):
        return None


def optimization(command: list[str]) -> str:
    for argument in command:
        if argument.startswith("-Doptimize="):
            return argument.split("=", 1)[1]
    return "unspecified"


def metadata(command: list[str], capture: Path, cases: int, samples: int) -> dict:
    parsed_samples, summaries = parse_text(capture.read_text(encoding="utf-8"))
    fixture_identity = {
        "%s/%s" % key: {
            "records": summary["records"],
            "body_bytes": summary["body_bytes"],
            "list_items": summary["list_items"],
            "fixture_digest": "%016x%016x" % (summary["fixture_digest_sum"], summary["fixture_digest_xor"]),
        }
        for key, summary in sorted(summaries.items())
    }
    fixture_identity_sha256 = hashlib.sha256(
        json.dumps(fixture_identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        "schema": "zply-phase12-capture-v1",
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "capture_file": capture.name,
        "capture_sha256": hashlib.sha256(capture.read_bytes()).hexdigest(),
        "command": command,
        "optimization": optimization(command),
        "source": {
            "git_commit": command_output(["git", "rev-parse", "HEAD"]),
            "git_status": command_output(["git", "status", "--porcelain"]),
            "zig_version": command_output(["zig", "version"]),
        },
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "cpu_model": cpu_model(),
            "cores": core_configuration(),
            "total_memory_bytes": total_memory_bytes(),
        },
        "capture": {
            "cases": cases,
            "samples": samples,
            "workload_modes": ["%s/%s" % key for key in sorted(parsed_samples)],
            "consumers": sorted({summary["consumer"] for summary in summaries.values()}),
            "executor": "std.Io.Threaded(single-threaded and concurrent_limit=4)",
            "input_source": "memory-backed std.Io.Reader",
            "fixture_identity": fixture_identity,
            "fixture_identity_sha256": fixture_identity_sha256,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="destination for benchmark stderr / CSV")
    parser.add_argument("--metadata", type=Path, help="JSON manifest destination (default: <capture>.json)")
    parser.add_argument("--require-full-matrix", action="store_true")

    # Keep the command strictly after `--`, but parse this wrapper's options
    # before that delimiter. argparse's REMAINDER action otherwise treats
    # options written after the positional capture path as subprocess
    # arguments, contradicting the documented invocation form.
    argv = sys.argv[1:]
    try:
        delimiter = argv.index("--")
    except ValueError:
        delimiter = len(argv)
        command: list[str] = []
    else:
        command = argv[delimiter + 1:]
    args = parser.parse_args(argv[:delimiter])
    if not command:
        parser.error("provide the benchmark command after --")

    result = subprocess.run(command, stderr=subprocess.PIPE, text=True)
    args.capture.parent.mkdir(parents=True, exist_ok=True)
    args.capture.write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print(f"benchmark command failed with exit code {result.returncode}; raw output kept at {args.capture}", file=sys.stderr)
        return result.returncode

    try:
        cases, samples = validate_text(result.stderr, args.require_full_matrix)
    except ValueError as exc:
        print(f"invalid Phase 12 capture: {exc}; raw output kept at {args.capture}", file=sys.stderr)
        return 1

    manifest_path = args.metadata or args.capture.with_suffix(args.capture.suffix + ".json")
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(metadata(command, args.capture, cases, samples), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Phase 12 capture valid: {cases} workload/mode cases, {samples} samples")
    print(f"wrote {args.capture} and {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
