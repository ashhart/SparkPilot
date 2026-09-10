"""Require hardware coverage or the prerequisite and command for collecting missing evidence."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from matrix_coverage import MatrixCoverage


class HardwareMatrix(MatrixCoverage):
    headings = ("49.4 Connectivity matrix", "49.7 Cluster matrix")
    coverage_path = Path(__file__).resolve().parent / "coverage.json"

    def test_every_plan_case_is_covered_or_declared(self) -> None:
        self.check_matrix()


if __name__ == "__main__":
    unittest.main()
