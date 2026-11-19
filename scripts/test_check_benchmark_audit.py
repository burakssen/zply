#!/usr/bin/env python3
"""Small standard-library regression tests for the M1 inventory validator."""

import json
import tempfile
import unittest
from pathlib import Path

from check_benchmark_audit import ROOT, validate


class AuditTests(unittest.TestCase):
    def test_repository_inventory(self):
        self.assertEqual([], validate(ROOT))

    def make_fixture(self, folder: Path):
        (folder / "benchmarks").mkdir()
        (folder / "benchmarks" / "sample.zig").write_text("pub fn main() void {}\n")
        (folder / "build.zig").write_text(
            'const _source = "benchmarks/sample.zig";\n'
            'const _step = b.step("bench-sample", "Benchmark sample");\n'
        )
        entry = {
            "source": "benchmarks/sample.zig",
            "step": "bench-sample",
            "origin": "test",
            "scope": "micro",
            "timed_boundary": "kernel only",
            "input": "fixed bytes",
            "execution": "single",
            "consumer": "digest",
            "warmups": 0,
            "measured_rounds": 3,
            "statistic": "best",
            "memory": "none",
            "limitations": "test",
        }
        manifest = {"schema_version": 1, "benchmarks": [entry]}
        (folder / "benchmarks" / "audit.json").write_text(json.dumps(manifest))
        return manifest

    def test_valid_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_fixture(root)
            self.assertEqual([], validate(root))

    def test_unlisted_benchmark_is_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_fixture(root)
            (root / "benchmarks" / "other.zig").write_text("pub fn main() void {}\n")
            self.assertTrue(any("missing benchmark audit entry" in issue for issue in validate(root)))

    def test_duplicate_source_is_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = self.make_fixture(root)
            entry = dict(manifest["benchmarks"][0])
            entry["step"] = "bench-other"
            manifest["benchmarks"].append(entry)
            (root / "benchmarks" / "audit.json").write_text(json.dumps(manifest))
            self.assertTrue(any("duplicate source" in issue for issue in validate(root)))

    def test_missing_build_step_is_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_fixture(root)
            (root / "build.zig").write_text('const _source = "benchmarks/sample.zig";\n')
            self.assertTrue(any("no b.step" in issue for issue in validate(root)))

    def test_invalid_scope_or_sample_count_is_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = self.make_fixture(root)
            entry = manifest["benchmarks"][0]
            entry["scope"] = "everything"
            entry["measured_rounds"] = 0
            (root / "benchmarks" / "audit.json").write_text(json.dumps(manifest))
            issues = validate(root)
            self.assertTrue(any("unknown scope" in issue for issue in issues))
            self.assertTrue(any("invalid measured_rounds" in issue for issue in issues))


if __name__ == "__main__":
    unittest.main()
