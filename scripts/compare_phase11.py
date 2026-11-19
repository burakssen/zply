#!/usr/bin/env python3
"""Compare M16 CSV captures from the same hardware and benchmark fixture.

Usage: python3 scripts/compare_phase11.py phase10.csv phase11.csv

No baseline data is fabricated. Missing or incompatible workloads are errors.
Median regression limits are policy knobs, not a statistical confidence test.
"""

import argparse
import csv
import math
import sys
from pathlib import Path

REQUIRED = (
    "workload", "mode", "records", "body_bytes", "list_items",
    "chunk_bytes", "budget_bytes", "warmups", "rounds",
    "median_ns", "p05_ns", "p95_ns", "records_per_s", "input_gbps",
    "list_items_per_s", "parser_peak_bytes", "batches",
    "native_submissions", "inline_decodes", "max_active", "digest_sum", "digest_xor",
)
CONFIG = ("workload", "mode", "records", "body_bytes", "list_items",
          "chunk_bytes", "budget_bytes", "warmups", "rounds")
KEY = ("workload", "mode")
EXPECTED_WORKLOADS = (
    "binary_xyz_f32", "binary_xyz_f64", "binary_xyzrgb",
    "binary_polygons_le", "binary_polygons_be", "ascii_xyz", "ascii_polygons",
)
EXPECTED_MODES = (
    "single-ordered", "threaded-ordered", "threaded-unordered", "single-small-chunk",
)
EXPECTED_KEYS = {(workload, mode) for workload in EXPECTED_WORKLOADS for mode in EXPECTED_MODES}
INT_FIELDS = ("records", "body_bytes", "list_items", "chunk_bytes",
              "budget_bytes", "warmups", "rounds", "median_ns", "p05_ns",
              "p95_ns", "parser_peak_bytes", "batches", "native_submissions",
              "inline_decodes", "max_active")
FLOAT_FIELDS = ("records_per_s", "input_gbps", "list_items_per_s")


def read_capture(path: Path) -> dict[tuple[str, str], dict]:
    # Zig's std.debug.print emits to stderr; `zig build` may prepend build
    # progress. Recognize only our exact CSV header and valid data records.
    lines = path.read_text(encoding="utf-8").splitlines()
    header = ",".join(REQUIRED)
    try:
        start = lines.index(header)
    except ValueError as exc:
        raise ValueError(f"{path}: missing M16 CSV header") from exc
    rows: dict[tuple[str, str], dict] = {}
    for line in lines[start + 1:]:
        if not line.startswith(("binary_", "ascii_")):
            continue
        values = next(csv.reader([line]))
        if len(values) != len(REQUIRED):
            raise ValueError(f"{path}: malformed CSV data row: {line}")
        record = dict(zip(REQUIRED, values))
        for field in INT_FIELDS:
            record[field] = int(record[field])
        for field in FLOAT_FIELDS:
            record[field] = float(record[field])
            if not math.isfinite(record[field]) or record[field] < 0:
                raise ValueError(f"{path}: invalid non-finite or negative {field}")
        for field in ("digest_sum", "digest_xor"):
            record[field] = int(record[field], 16)
        if record["median_ns"] <= 0 or not (
            0 < record["p05_ns"] <= record["median_ns"] <= record["p95_ns"]
        ):
            raise ValueError(f"{path}: invalid latency distribution for {record['workload']}")
        if record["batches"] <= 0 or record["parser_peak_bytes"] > record["budget_bytes"]:
            raise ValueError(f"{path}: invalid budget/batch counters for {record['workload']}")
        key = tuple(record[field] for field in KEY)
        if key in rows:
            raise ValueError(f"{path}: duplicate workload/mode: {key}")
        rows[key] = record
    if not rows:
        raise ValueError(f"{path}: M16 CSV has no result rows")
    return rows


def change(current: int | float, baseline: int | float) -> float:
    if baseline == 0:
        return 0.0 if current == 0 else math.inf
    return (current / baseline - 1) * 100


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("current", type=Path)
    parser.add_argument("--max-median-regression-pct", type=float, default=15.0)
    parser.add_argument("--max-peak-growth-pct", type=float, default=10.0)
    parser.add_argument("--warn-only", action="store_true", help="report, but do not exit nonzero on regressions")
    parser.add_argument("--require-full-matrix", action="store_true", help="require all 28 M16 workload/mode pairs")
    args = parser.parse_args()
    if args.max_median_regression_pct < 0 or args.max_peak_growth_pct < 0:
        parser.error("regression thresholds must be nonnegative")
    try:
        before = read_capture(args.baseline)
        after = read_capture(args.current)
        if args.require_full_matrix and (before.keys() != EXPECTED_KEYS or after.keys() != EXPECTED_KEYS):
            raise ValueError("a capture does not contain the full 28-row M16 workload/mode matrix")
        if before.keys() != after.keys():
            missing = sorted(before.keys() - after.keys())
            extra = sorted(after.keys() - before.keys())
            raise ValueError(f"benchmark keys differ; missing={missing}, extra={extra}")
        failures = 0
        print("workload / mode                         median ms (before -> after)    median delta    p95 delta    peak delta   status")
        for key in sorted(before):
            b, a = before[key], after[key]
            if any(b[field] != a[field] for field in CONFIG):
                raise ValueError(f"incompatible fixture/run configuration for {key}")
            if b["digest_sum"] != a["digest_sum"] or b["digest_xor"] != a["digest_xor"]:
                raise ValueError(f"decoded digest changed for {key}")
            median_delta = change(a["median_ns"], b["median_ns"])
            p95_delta = change(a["p95_ns"], b["p95_ns"])
            peak_delta = change(a["parser_peak_bytes"], b["parser_peak_bytes"])
            regressed = (median_delta > args.max_median_regression_pct or
                         peak_delta > args.max_peak_growth_pct)
            failures += int(regressed)
            label = f"{key[0]} / {key[1]}"
            print(f"{label:39} {b['median_ns']/1e6:8.3f} -> {a['median_ns']/1e6:8.3f}"
                  f"      {median_delta:+8.2f}%   {p95_delta:+8.2f}%  {peak_delta:+8.2f}%   "
                  f"{'REGRESSION' if regressed else 'ok'}")
        print(f"\n{len(before)} matched workload/mode pairs; {failures} over policy thresholds.")
        print("Compare captures from the same CPU, Zig version and machine conditions."
              " Thresholds are screening rules, not statistical significance.")
        return 0 if failures == 0 or args.warn_only else 1
    except (OSError, ValueError) as exc:
        print(f"comparison error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
