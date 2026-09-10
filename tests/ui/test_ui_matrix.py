"""Map app-owned decisions to tests and preserve device evidence requirements for layout and accessibility."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from matrix_coverage import MatrixCoverage


class AppExperienceMatrix(MatrixCoverage):
    heading = "49.8 App experience matrix"
    coverage_path = Path(__file__).resolve().parent / "coverage.json"

    def test_every_plan_case_is_covered_or_declared(self) -> None:
        self.check_matrix()


if __name__ == "__main__":
    unittest.main()
