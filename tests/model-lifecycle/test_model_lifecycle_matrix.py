"""Map model-lifecycle cases to tests and retain real-engine, gated-repository and timed-idle blockers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from matrix_coverage import MatrixCoverage


class ModelLifecycleMatrix(MatrixCoverage):
    heading = "49.5 Model lifecycle matrix"
    coverage_path = Path(__file__).resolve().parent / "coverage.json"

    def test_every_plan_case_is_covered_or_declared(self) -> None:
        self.check_matrix()


if __name__ == "__main__":
    unittest.main()
