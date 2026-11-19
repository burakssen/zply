#!/usr/bin/env python3
"""Dependency-free tests for the Phase 11 CSV regression comparator."""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import compare_phase11


HEADER = ",".join(compare_phase11.REQUIRED)


def row(median: int = 1_000_000, peak: int = 2048, mode: str = "single-ordered", workload: str = "binary_xyz_f32") -> str:
    values = {
        "workload": workload, "mode": mode, "records": 250000,
        "body_bytes": 3000000, "list_items": 0, "chunk_bytes": 262144,
        "budget_bytes": 16777216, "warmups": 2, "rounds": 9,
        "median_ns": median, "p05_ns": median // 2,
        "p95_ns": median * 2, "records_per_s": 250000000.0,
        "input_gbps": 3.0, "list_items_per_s": 0.0,
        "parser_peak_bytes": peak, "batches": 12,
        "native_submissions": 0, "inline_decodes": 12,
        "max_active": 1, "digest_sum": "abcd", "digest_xor": "dcba",
    }
    return ",".join(str(values[field]) for field in compare_phase11.REQUIRED)


class ComparePhase11Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.before = base / "before.csv"
        self.after = base / "after.csv"
        self.before.write_text("[0/3] steps\n" + HEADER + "\n" + row() + "\n", encoding="utf-8")
        self.after.write_text(HEADER + "\n" + row() + "\n", encoding="utf-8")

    def run_compare(self, *options: str) -> int:
        with patch("sys.argv", ["compare_phase11.py", str(self.before), str(self.after), *options]):
            with contextlib.redirect_stdout(io.StringIO()):
                return compare_phase11.main()

    def test_identical_and_noise_prefix(self):
        self.assertEqual(0, self.run_compare())

    def test_complete_matrix_accepted(self):
        lines = [row(mode=mode, workload=workload)
                 for workload in compare_phase11.EXPECTED_WORKLOADS
                 for mode in compare_phase11.EXPECTED_MODES]
        content = HEADER + "\n" + "\n".join(lines) + "\n"
        self.before.write_text(content, encoding="utf-8")
        self.after.write_text(content, encoding="utf-8")
        self.assertEqual(0, self.run_compare("--require-full-matrix"))

    def test_partial_matrix_can_be_rejected(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, self.run_compare("--require-full-matrix"))

    def test_regression_fails_and_warn_only_succeeds(self):
        self.after.write_text(HEADER + "\n" + row(1_500_000) + "\n", encoding="utf-8")
        self.assertEqual(1, self.run_compare())
        self.assertEqual(0, self.run_compare("--warn-only"))

    def test_incompatible_fixture_fails(self):
        self.after.write_text(HEADER + "\n" + row(mode="threaded-ordered") + "\n", encoding="utf-8")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, self.run_compare())

    def test_peak_growth_fails(self):
        self.after.write_text(HEADER + "\n" + row(peak=4096) + "\n", encoding="utf-8")
        self.assertEqual(1, self.run_compare())

    def test_corrupt_digest_fails(self):
        self.after.write_text(HEADER + "\n" + row().replace("abcd", "babe") + "\n", encoding="utf-8")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, self.run_compare())


if __name__ == "__main__":
    unittest.main()
