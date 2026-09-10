"""Keep docs/ERROR_CODES.md honest about the codes this repository actually sends."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CODES = ROOT / "docs" / "ERROR_CODES.md"

#: Where a code could be produced or consumed: the runtime, the app, the cloud and the contracts.
SEARCHED = ("runtime", "apple", "cloud", "contracts", "tools", "packaging")
SEARCHED_SUFFIXES = {".rs", ".swift", ".ts", ".tsx", ".js", ".py", ".yaml", ".yml", ".json", ".sql"}
SKIPPED_DIRECTORIES = {".git", "target", "node_modules", ".build", "DerivedData", "Pods"}
#: The app's owner-copy tables name every documented code so they can explain it; naming is not sending.
CONSUMER_FILE_PREFIXES = ("SparkErrorCopy",)

#: A table row opens with the code.
ROW = re.compile(r"^\|\s*([A-Z][A-Z0-9_]{3,})\s*\|(.*)$", re.MULTILINE)

#: Documented codes with no producer anywhere in this repository; each is marked **Reserved** in its row, and a name comes out of here on the same commit that starts sending it.
RESERVED_CODES = frozenset(
    {
        "AGENT_APPROVAL_REQUIRED",
        "AGENT_POLICY_DENIED",
        "API_VERSION_UNSUPPORTED",
        "BUILD_WORKER_UNAVAILABLE",
        "CLUSTER_COLLECTIVE_TEST_FAILED",
        "CLUSTER_LINK_UNHEALTHY",
        "CLUSTER_NODE_UNREACHABLE",
        "CLUSTER_VERSION_MISMATCH",
        "CLUSTER_WORKER_LOST",
        "MODEL_DRAIN_TIMEOUT",
        "MODEL_LICENCE_REQUIRED",
        "MODEL_UNLOAD_FAILED",
        "NODE_NOT_REACHABLE",
        "PROJECT_CONFLICT",
        "REMOTE_ACCESS_UNAVAILABLE",
        "TLS_IDENTITY_MISMATCH",
        "UPDATE_INCOMPATIBLE",
        "UPDATE_ROLLED_BACK",
        "UPDATE_SIGNATURE_INVALID",
    }
)


def documented_rows() -> dict[str, str]:
    return {match.group(1): match.group(2) for match in ROW.finditer(CODES.read_text(encoding="utf-8"))}


@lru_cache(maxsize=1)
def sources() -> tuple[str, ...]:
    texts = []
    for top in SEARCHED:
        directory = ROOT / top
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            if not path.is_file() or path.suffix not in SEARCHED_SUFFIXES:
                continue
            if any(part in SKIPPED_DIRECTORIES for part in path.parts):
                continue
            if path.name.startswith(CONSUMER_FILE_PREFIXES):
                continue
            texts.append(path.read_text(encoding="utf-8", errors="ignore"))
    return tuple(texts)


def used_codes(candidates: frozenset[str]) -> set[str]:
    # One alternation over the whole corpus, so the scan is a single pass per file.
    pattern = re.compile(r"\b(" + "|".join(sorted(candidates)) + r")\b")
    found: set[str] = set()
    for text in sources():
        found.update(pattern.findall(text))
    return found


class ErrorCodeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rows = documented_rows()
        self.used = used_codes(frozenset(self.rows))

    def test_the_table_parses(self) -> None:
        self.assertGreater(len(self.rows), 100, "the error-code parser found almost nothing")
        self.assertIn("OPERATION_CANCELLED", self.rows)

    def test_every_documented_code_is_sent_or_reserved(self) -> None:
        unsent = sorted(set(self.rows) - self.used - RESERVED_CODES)
        self.assertEqual(
            unsent,
            [],
            "docs/ERROR_CODES.md says a client should act on these and nothing sends them. "
            "Send them, or add them to RESERVED_CODES and mark the row **Reserved**.",
        )

    def test_no_reserved_code_is_being_sent(self) -> None:
        sent = sorted(RESERVED_CODES & self.used)
        self.assertEqual(
            sent,
            [],
            "these are sent now; take them out of RESERVED_CODES and correct their rows",
        )

    def test_every_reserved_code_says_so_in_its_row(self) -> None:
        unmarked = sorted(code for code in RESERVED_CODES if "Reserved" not in self.rows.get(code, ""))
        self.assertEqual(unmarked, [], "a client reading the table would think these arrive")

    def test_reserved_codes_are_all_documented(self) -> None:
        missing = sorted(RESERVED_CODES - set(self.rows))
        self.assertEqual(missing, [], "RESERVED_CODES names a code the table does not have")

    def test_the_automation_timezone_codes_are_both_documented(self) -> None:
        # BH-48: AUTOMATION_TIMEZONE_UNREADABLE was emitted by the runtime and undocumented.
        for code in ("AUTOMATION_TIMEZONE_UNKNOWN", "AUTOMATION_TIMEZONE_UNREADABLE"):
            self.assertIn(code, self.rows)


if __name__ == "__main__":
    unittest.main()
