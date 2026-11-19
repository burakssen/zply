#!/usr/bin/env python3
"""Validate Phase 12 M2 CSV samples and summaries, without guessing missing data.

Usage: python3 scripts/check_phase12_capture.py phase12.csv [--require-full-matrix]
"""
from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

HEADER = (
    'row_type','workload','mode','records','body_bytes','list_items','chunk_bytes',
    'budget_bytes','warmups','rounds','round','lifecycle_ns','body_ns',
    'lifecycle_p05_ns','lifecycle_p95_ns','body_p05_ns','body_p95_ns',
    'records_per_s','input_gbps','list_items_per_s','parser_peak_bytes',
    'batches','native_submissions','inline_decodes','max_active','digest_sum','digest_xor',
)
INTS = set(HEADER) - {
    'row_type','workload','mode','records_per_s','input_gbps','list_items_per_s','digest_sum','digest_xor',
}
FIELDS_SAME = {
    'workload','mode','records','body_bytes','list_items','chunk_bytes','budget_bytes',
    'warmups','rounds','digest_sum','digest_xor',
}
WORKLOADS = {
    'binary_xyz_f32','binary_xyz_f64','binary_xyzrgb',
    'binary_polygons_le','binary_polygons_be','ascii_xyz','ascii_polygons',
}
MODES = {'single-ordered','threaded-ordered','threaded-unordered','single-small-chunk'}


def rank(values: list[int], pct: int) -> int:
    return sorted(values)[max(1,(len(values)*pct+99)//100)-1]


def validate_text(text: str, require_full_matrix: bool = False) -> tuple[int, int]:
    # Zig Build may prepend diagnostic progress to the stderr capture.
    lines = text.splitlines()
    try:
        start = lines.index(','.join(HEADER))
    except ValueError as exc:
        raise ValueError('missing Phase 12 CSV header') from exc
    samples = defaultdict(list)
    summaries = {}
    for line in lines[start + 1:]:
        if not line.startswith(('sample,','summary,')):
            continue
        cells = next(csv.reader([line]))
        if len(cells) != len(HEADER):
            raise ValueError(f'wrong CSV column count: {line}')
        row = dict(zip(HEADER, cells))
        for field in INTS:
            row[field] = int(row[field])
        for field in ('digest_sum','digest_xor'):
            row[field] = int(row[field], 16)
        for field in ('records_per_s','input_gbps','list_items_per_s'):
            row[field] = float(row[field])
            if not math.isfinite(row[field]) or row[field] < 0:
                raise ValueError(f'invalid throughput {field}')
        if row['workload'] not in WORKLOADS or row['mode'] not in MODES:
            raise ValueError('unknown workload or mode')
        if row['records'] <= 0 or row['rounds'] <= 0 or row['warmups'] < 0:
            raise ValueError('invalid run parameters')
        if row['lifecycle_ns'] < row['body_ns'] or row['body_ns'] <= 0:
            raise ValueError('invalid timing scope')
        if row['parser_peak_bytes'] > row['budget_bytes'] or row['batches'] <= 0:
            raise ValueError('invalid memory or batch counters')
        if row['mode'].startswith('threaded-') and row['native_submissions'] <= 0:
            raise ValueError('threaded mode executed without native tasks')
        key = (row['workload'],row['mode'])
        if row['row_type'] == 'sample':
            if row['round'] < 0:
                raise ValueError('negative sample round')
            samples[key].append(row)
        else:
            if row['round'] != -1 or key in summaries:
                raise ValueError('duplicate summary or invalid summary round')
            summaries[key] = row
    if not samples or summaries.keys() != samples.keys():
        raise ValueError('missing samples or summaries')
    if require_full_matrix and set(samples) != {(a,b) for a in WORKLOADS for b in MODES}:
        raise ValueError('expected 28 workload/mode combinations')
    for key, rows in samples.items():
        summary = summaries[key]
        if len(rows) != summary['rounds'] or {r['round'] for r in rows} != set(range(summary['rounds'])):
            raise ValueError(f'missing or repeated sample rounds for {key}')
        for row in rows:
            if any(row[f] != summary[f] for f in FIELDS_SAME):
                raise ValueError(f'incompatible sample and summary metadata for {key}')
        life = sorted(r['lifecycle_ns'] for r in rows)
        body = sorted(r['body_ns'] for r in rows)
        for actual, expected in (
            (summary['lifecycle_ns'], life[len(life)//2]),
            (summary['body_ns'], body[len(body)//2]),
            (summary['lifecycle_p05_ns'], rank(life,5)),
            (summary['lifecycle_p95_ns'], rank(life,95)),
            (summary['body_p05_ns'], rank(body,5)),
            (summary['body_p95_ns'], rank(body,95)),
            (summary['parser_peak_bytes'], max(r['parser_peak_bytes'] for r in rows)),
        ):
            if actual != expected:
                raise ValueError(f'bad summary statistic for {key}: {actual} != {expected}')
    return len(samples), sum(map(len,samples.values()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture',type=Path)
    parser.add_argument('--require-full-matrix',action='store_true')
    args = parser.parse_args()
    try:
        cases, count = validate_text(args.capture.read_text(), args.require_full_matrix)
    except (OSError, ValueError) as exc:
        print(f'invalid Phase 12 capture: {exc}',file=sys.stderr)
        return 1
    print(f'Phase 12 capture valid: {cases} workload/mode cases, {count} samples')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
