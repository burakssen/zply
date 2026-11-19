#!/usr/bin/env python3
"""Regression tests for the Phase 12 capture-wrapper command boundary."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CAPTURE = ROOT / "scripts" / "capture_phase12.py"


class CaptureCommandBoundaryTest(unittest.TestCase):
    def test_wrapper_options_after_capture_path_are_not_subprocess_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.csv"
            metadata = Path(temporary) / "capture.json"
            command = [
                sys.executable,
                str(CAPTURE),
                str(capture),
                "--metadata",
                str(metadata),
                "--require-full-matrix",
                "--",
                sys.executable,
                "-c",
                "import sys; sys.stderr.write('not a Phase 12 capture\\n')",
            ]
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)

            # Validation fails after the subprocess has run, proving that
            # options following the capture path did not become its argv.
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertTrue(capture.exists())
            self.assertIn("missing Phase 12 CSV header", result.stderr)
            self.assertFalse(metadata.exists())


if __name__ == "__main__":
    unittest.main()
