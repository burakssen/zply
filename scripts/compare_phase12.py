#!/usr/bin/env python3
"""Compare two validated Phase 12 benchmark captures.

Usage: python3 scripts/compare_phase12.py baseline.csv candidate.csv

Use only captures with the same fixture, parser configuration, consumer mode,
compiler, and machine. The optional JSON manifests emitted by capture_phase12
are checked when present. Thresholds are review signals, not confidence tests.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

from check_phase12_capture import MODES, WORKLOADS, parse_text, validate_text

KEY = ("workload", "mode")
CONFIG = (
    "workload", "mode", "consumer", "records", "body_bytes", "list_items",
    "chunk_bytes", "budget_bytes", "warmups", "rounds",
    "fixture_digest_sum", "fixture_digest_xor",
)


def change(candidate: int, baseline: int) -> float:
    return (candidate / baseline - 1.0) * 100.0


def read_capture(path: Path) -> dict[tuple[str, str], dict]:
    text = path.read_text(encoding="utf-8")
    validate_text(text)
    _, summaries = parse_text(text)
    return summaries


def read_metadata(path: Path) -> dict | None:
    metadata_path = path.with_suffix(path.suffix + ".json")
    if not metadata_path.exists():
        return None
    document = json.loads(metadata_path.read_text(encoding="utf-8"))
    if document.get("schema") != "zply-phase12-capture-v1":
        raise ValueError(f"{metadata_path}: unsupported capture metadata schema")
    return document


def metadata_compatibility(baseline: dict | None, candidate: dict | None) -> list[str]:
    if baseline is None or candidate is None:
        return ["metadata manifest missing; compiler and hardware compatibility was not checked"]
    fields = (
        ("optimization",),
        ("source", "zig_version"),
        ("platform", "system"),
        ("platform", "machine"),
        ("platform", "cpu_model"),
        ("capture", "executor"),
    )
    warnings = []
    for path in fields:
        before = baseline
        after = candidate
        for component in path:
            before = before.get(component)
            after = after.get(component)
        if before != after:
            warnings.append(f"metadata differs for {'.'.join(path)}: {before!r} != {after!r}")
    return warnings


def compare(
    baseline: dict[tuple[str, str], dict],
    candidate: dict[tuple[str, str], dict],
    timing_scope: str,
    max_regression_pct: float,
    max_peak_growth_pct: float,
) -> tuple[list[str], int]:
    if baseline.keys() != candidate.keys():
        missing = sorted(baseline.keys() - candidate.keys())
        extra = sorted(candidate.keys() - baseline.keys())
        raise ValueError(f"benchmark keys differ; missing={missing}, extra={extra}")
    latency_field = f"{timing_scope}_ns"
    p05_field = f"{timing_scope}_p05_ns"
    p95_field = f"{timing_scope}_p95_ns"
    lines = [
        f"workload / mode / consumer{' ' * 20} {timing_scope} median ms (baseline -> candidate)    median     p05     p95    rec/s   GB/s   alloc    peak   status"
    ]
    failures = 0
    for key in sorted(baseline):
        before, after = baseline[key], candidate[key]
        if any(before[field] != after[field] for field in CONFIG):
            raise ValueError(f"incompatible fixture/run configuration for {key}")
        if (before["consumer_digest_sum"], before["consumer_digest_xor"]) != (
            after["consumer_digest_sum"], after["consumer_digest_xor"]):
            raise ValueError(f"consumer digest changed for {key}")
        median_delta = change(after[latency_field], before[latency_field])
        p05_delta = change(after[p05_field], before[p05_field])
        p95_delta = change(after[p95_field], before[p95_field])
        record_delta = change(after["records_per_s"], before["records_per_s"])
        input_delta = change(after["input_gbps"], before["input_gbps"])
        allocation_delta = change(after["allocation_count"], before["allocation_count"])
        peak_delta = change(after["parser_peak_bytes"], before["parser_peak_bytes"])
        regressed = median_delta > max_regression_pct or peak_delta > max_peak_growth_pct
        failures += int(regressed)
        label = f"{key[0]} / {key[1]} / {before['consumer']}"
        lines.append(
            f"{label:49} {before[latency_field] / 1e6:8.3f} -> {after[latency_field] / 1e6:8.3f}"
            f"      {median_delta:+6.2f}% {p05_delta:+6.2f}% {p95_delta:+6.2f}%"
            f" {record_delta:+6.2f}% {input_delta:+6.2f}% {allocation_delta:+6.2f}% {peak_delta:+6.2f}%   "
            f"{'REGRESSION' if regressed else 'ok'}"
        )
    return lines, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--timing-scope", choices=("body", "lifecycle"), default="body")
    parser.add_argument("--max-median-regression-pct", type=float, default=10.0)
    parser.add_argument("--max-peak-growth-pct", type=float, default=10.0)
    parser.add_argument("--require-full-matrix", action="store_true")
    parser.add_argument("--warn-only", action="store_true")
    args = parser.parse_args()
    if args.max_median_regression_pct < 0 or args.max_peak_growth_pct < 0:
        parser.error("regression thresholds must be nonnegative")
    try:
        baseline = read_capture(args.baseline)
        candidate = read_capture(args.candidate)
        expected_keys = {(workload, mode) for workload in WORKLOADS for mode in MODES}
        if args.require_full_matrix and (baseline.keys() != expected_keys or candidate.keys() != expected_keys):
            raise ValueError("a capture does not contain the full 64 Phase 12 workload/mode pairs")
        lines, failures = compare(
            baseline,
            candidate,
            args.timing_scope,
            args.max_median_regression_pct,
            args.max_peak_growth_pct,
        )
        print("\n".join(lines))
        for warning in metadata_compatibility(read_metadata(args.baseline), read_metadata(args.candidate)):
            print(f"warning: {warning}", file=sys.stderr)
        print(f"\n{len(baseline)} matched workload/mode pairs; {failures} over policy thresholds.")
        return 0 if failures == 0 or args.warn_only else 1
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"comparison error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
