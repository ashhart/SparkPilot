"""The committed coverage registers must run without an external historical plan."""

import unittest
from unittest.mock import patch

from matrix_coverage import MatrixCoverage


class CoverageGateTests(unittest.TestCase):
    def test_missing_test_is_rejected_even_without_the_old_plan(self):
        gate = MatrixCoverage()
        gate.heading = "49.8 App experience matrix"
        with patch.object(
            MatrixCoverage, "load", return_value={"cases": {"A working button": {"tests": ["missing_test"]}}}
        ), patch("matrix_coverage.symbol_exists", return_value=False):
            try:
                with self.assertRaisesRegex(AssertionError, "mapped tests that no longer exist"):
                    gate.check_matrix()
            except unittest.SkipTest:
                self.fail("The missing historical plan skipped the actual coverage check")

    def test_a_case_with_neither_tests_nor_a_blocker_is_rejected(self):
        gate = MatrixCoverage()
        gate.heading = "49.8 App experience matrix"
        with patch.object(MatrixCoverage, "load", return_value={"cases": {"A working button": {}}}):
            try:
                with self.assertRaisesRegex(AssertionError, "neither tests nor a declared blocker"):
                    gate.check_matrix()
            except unittest.SkipTest:
                self.fail("The missing historical plan skipped the actual coverage check")


if __name__ == "__main__":
    unittest.main()
