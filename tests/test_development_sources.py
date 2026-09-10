"""Vendored source verification must cover both upstream files and reviewed patches."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "development_sources", ROOT / "tools/check-development-sources.py"
)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


class TerminalSourceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.sources = self.root / "vendor/Sources/SwiftTerm"
        self.sources.mkdir(parents=True)
        self.original = "let value = 1\n"
        (self.sources / "Buffer.swift").write_text(self.original)
        (self.sources / "SwiftTermBuildInfo.swift").write_text("fixed-revision")
        (self.root / "vendor/LICENSE").write_text("MIT")
        (self.root / "vendor/Package.swift").write_text("// library only\n")
        (self.root / "hashes.json").write_text(json.dumps({"Buffer.swift": digest(self.original)}))
        self.terminal = {
            "path": "vendor", "source_hashes": "hashes.json", "revision": "fixed-revision"
        }

    def check(self):
        return CHECKER.verify_terminal_sources(self.root, self.terminal)

    def test_upstream_source_passes(self):
        self.assertEqual(self.check(), (1, 0))

    def test_unrecorded_change_is_rejected(self):
        (self.sources / "Buffer.swift").write_text("changed")
        with self.assertRaisesRegex(AssertionError, "Buffer.swift"):
            self.check()

    def test_reviewed_patch_passes_without_rewriting_upstream_baseline(self):
        (self.sources / "Buffer.swift").write_text("reviewed change")
        self.terminal["local_source_hashes"] = {"Buffer.swift": digest("reviewed change")}
        self.assertEqual(self.check(), (1, 1))
        self.assertEqual(json.loads((self.root / "hashes.json").read_text()),
                         {"Buffer.swift": digest(self.original)})

    def test_drift_after_review_is_rejected(self):
        self.terminal["local_source_hashes"] = {"Buffer.swift": digest("reviewed change")}
        (self.sources / "Buffer.swift").write_text("unreviewed change")
        with self.assertRaisesRegex(AssertionError, "Buffer.swift"):
            self.check()

    def test_unknown_patch_cannot_expand_the_inventory(self):
        self.terminal["local_source_hashes"] = {"Extra.swift": digest("extra")}
        with self.assertRaisesRegex(AssertionError, "unknown source"):
            self.check()

    def test_added_source_is_rejected(self):
        (self.sources / "Extra.swift").write_text("extra")
        with self.assertRaisesRegex(AssertionError, "inventory"):
            self.check()

    def test_deleted_source_is_rejected(self):
        (self.sources / "Buffer.swift").unlink()
        with self.assertRaisesRegex(AssertionError, "inventory"):
            self.check()

    def test_invalid_patch_digest_is_rejected(self):
        self.terminal["local_source_hashes"] = {"Buffer.swift": "not-a-digest"}
        with self.assertRaisesRegex(AssertionError, "Buffer.swift"):
            self.check()

    def test_redundant_patch_is_rejected(self):
        self.terminal["local_source_hashes"] = {"Buffer.swift": digest(self.original)}
        with self.assertRaisesRegex(AssertionError, "Redundant"):
            self.check()


if __name__ == "__main__":
    unittest.main()
