"""Match committed coverage cases to existing test symbols or declared blockers; see docs/build/TOOLING-INVARIANTS.md."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def symbol_exists(symbol: str) -> bool:
    """Find the test by name across the tree so file moves preserve its coverage identity."""
    # Include uncommitted test evidence and search each symbol literally.
    for needle in (f"fn {symbol}(", f"func {symbol}(", f"def {symbol}("):
        result = subprocess.run(
            ["git", "grep", "--untracked", "-lF", "--", needle],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return True
    return False


class MatrixCoverage(unittest.TestCase):
    """Base class: set `heading` and `coverage_path` in a subclass."""

    heading: str = ""
    #: Combine related plan sections into one coverage map.
    headings: tuple[str, ...] = ()
    coverage_path: Path | None = None

    @classmethod
    def load(cls) -> dict:
        assert cls.coverage_path is not None
        return json.loads(cls.coverage_path.read_text(encoding="utf-8"))

    def check_matrix(self) -> None:
        headings = self.headings or (self.heading,)
        # Validate preserved acceptance cases without depending on the retired external plan.
        coverage = self.load()
        mapped = coverage["cases"]
        self.assertIsInstance(mapped, dict, "coverage cases must be a named register")
        self.assertTrue(mapped, "the coverage register must not be empty")

        missing_tests: list[str] = []
        blocked: list[str] = []
        for case, entry in mapped.items():
            self.assertTrue(case.strip(), "a coverage case needs a description")
            if "retired" in entry:
                self.assertTrue(entry["retired"].strip(), f"{case}: retirement needs its product decision")
                print(f"  RETIRED  {case}: {entry['retired']}")
            if "blocked" in entry:
                self.assertIn(
                    "reason", entry["blocked"], f"{case}: a blocker needs a reason"
                )
                self.assertIn(
                    "evidence_command",
                    entry["blocked"],
                    f"{case}: a blocker needs the command that would produce the "
                    f"missing evidence",
                )
                blocked.append(f"  BLOCKED  {case}\n           {entry['blocked']['reason']}")
                continue
            tests = entry.get("tests", [])
            self.assertTrue(tests, f"{case}: neither tests nor a declared blocker")
            for test in tests:
                if not symbol_exists(test):
                    missing_tests.append(f"{case} -> {test}")

        self.assertEqual(
            missing_tests,
            [],
            f"{', '.join(headings)}: mapped tests that no longer exist. A renamed or "
            f"deleted test is lost coverage, not a passing matrix.",
        )

        if blocked:
            print(f"\n{', '.join(headings)}: {len(blocked)} case(s) not covered here:")
            print("\n".join(blocked))
