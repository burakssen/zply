#!/usr/bin/env python3
"""Offline regression tests for the Phase 12 capture comparison utility."""
from __future__ import annotations

import unittest

from check_phase12_capture import HEADER, parse_text
from compare_phase12 import compare


def row(
    kind: str,
    round_number: int,
    lifecycle: int,
    body: int,
    *,
    lifecycle_p05: int | None = None,
    lifecycle_p95: int | None = None,
    body_p05: int | None = None,
    body_p95: int | None = None,
    consumer_digest: str = "abcd",
    peak: int = 64,
) -> str:
    values = {
        "row_type": kind, "workload": "binary_xyz_f32", "mode": "single-ordered",
        "consumer": "validation", "records": 128, "body_bytes": 1536, "list_items": 0,
        "chunk_bytes": 4096, "budget_bytes": 1048576, "warmups": 1, "rounds": 3,
        "round": round_number, "lifecycle_ns": lifecycle, "body_ns": body,
        "lifecycle_p05_ns": lifecycle if lifecycle_p05 is None else lifecycle_p05,
        "lifecycle_p95_ns": lifecycle if lifecycle_p95 is None else lifecycle_p95,
        "body_p05_ns": body if body_p05 is None else body_p05,
        "body_p95_ns": body if body_p95 is None else body_p95, "records_per_s": 100.0,
        "input_gbps": 0.01, "list_items_per_s": 0.0, "parser_peak_bytes": peak, "allocation_count": 8,
        "batches": 1, "native_submissions": 0, "inline_decodes": 1, "max_active": 1,
        "fixture_digest_sum": "abcd", "fixture_digest_xor": "1234",
        "consumer_digest_sum": consumer_digest, "consumer_digest_xor": "1234",
    }
    return ",".join(str(values[key]) for key in HEADER)


def capture(median_body: int = 30, digest: str = "abcd") -> dict:
    rows = [
        row("sample", 0, 40, 20, consumer_digest=digest),
        row("sample", 1, 50, median_body, consumer_digest=digest),
        row("sample", 2, 60, 40, consumer_digest=digest),
        row(
            "summary", -1, 50, median_body,
            lifecycle_p05=40, lifecycle_p95=60,
            body_p05=20, body_p95=40, consumer_digest=digest,
        ),
    ]
    _, summaries = parse_text("\n".join((",".join(HEADER), *rows)))
    return summaries


class CompareTests(unittest.TestCase):
    def test_reports_improvement(self) -> None:
        lines, failures = compare(capture(30), capture(20), "body", 10.0, 10.0)
        self.assertEqual(0, failures)
        self.assertIn("-33.33%", "\n".join(lines))

    def test_detects_regression(self) -> None:
        _, failures = compare(capture(30), capture(40), "body", 10.0, 10.0)
        self.assertEqual(1, failures)

    def test_rejects_digest_change(self) -> None:
        with self.assertRaisesRegex(ValueError, "consumer digest"):
            compare(capture(), capture(digest="beef"), "body", 10.0, 10.0)


if __name__ == "__main__":
    unittest.main()
