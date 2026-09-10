"""Check accessibility plan coverage, source wiring and explicit evidence blockers."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from matrix_coverage import MatrixCoverage


class AccessibilityMatrix(MatrixCoverage):
    headings = ("51.1 Accessibility",)
    coverage_path = Path(__file__).resolve().parent / "coverage.json"

    def test_every_plan_case_is_covered_or_declared(self) -> None:
        self.check_matrix()

    def test_partial_coverage_names_what_is_missing(self) -> None:
        """Require partial coverage to identify the missing behavior and its prerequisite."""
        cases = json.loads(self.coverage_path.read_text(encoding="utf-8"))["cases"]
        for clause, entry in cases.items():
            partial = entry.get("partial")
            if partial is None:
                continue
            with self.subTest(clause=clause):
                for field in ("covered", "not_covered", "blocked_on"):
                    self.assertTrue(
                        partial.get(field),
                        f"{clause} is partial without saying its {field}",
                    )

    def test_the_seams_are_actually_wired_into_the_views(self) -> None:
        """Require each accessibility announcement helper to remain connected to its view."""
        cases = json.loads(self.coverage_path.read_text(encoding="utf-8"))["cases"]
        root = Path(__file__).resolve().parents[2]
        for clause, entry in cases.items():
            wiring = entry.get("wiring")
            if wiring is None:
                continue
            with self.subTest(clause=clause):
                source = root / wiring["file"]
                self.assertTrue(source.is_file(), f"{wiring['file']} is not in the tree")
                text = source.read_text(encoding="utf-8")
                for fragment in wiring.get("forbids", []):
                    self.assertTrue(
                        fragment not in text,
                        f"{clause}: {wiring['file']} decides presentation by "
                        f"comparing rendered copy\n  {fragment}\n"
                        f"which holds in one language and no other",
                    )
                for fragment in wiring["requires"]:
                    # Avoid printing the entire source file when only one missing line matters.
                    self.assertTrue(
                        fragment in text,
                        f"{clause}: {wiring['file']} no longer applies\n"
                        f"  {fragment}\n"
                        f"so the shipping view stopped announcing it",
                    )

    def test_physical_checks_carry_a_command_and_an_expectation(self) -> None:
        document = json.loads(self.coverage_path.read_text(encoding="utf-8"))
        physical = document["physical"]
        self.assertTrue(physical, "no physical accessibility run is declared")
        for name, entry in physical.items():
            with self.subTest(check=name):
                for field in ("reason", "evidence_command", "expected_evidence"):
                    self.assertTrue(entry.get(field), f"{name} has no {field}")
        print(f"\n== PLAN §51.1: {len(physical)} checks need a device:")
        for name in physical:
            print(f"  PHYSICAL  {name}")

if __name__ == "__main__":
    unittest.main()
