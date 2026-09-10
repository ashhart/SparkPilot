from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from check_generated_outputs import (
    LEGACY_RUST_OUTPUT,
    owned_output_path,
    present_generated_outputs,
    remove_obsolete_outputs,
    stale_generated_outputs,
)


class GeneratedOutputOwnershipTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, relative: str, contents: str = "generated\n") -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def manifest(self, outputs: list[str]) -> None:
        self.write("contracts/generated/manifest.json", json.dumps({"outputs": outputs}))

    def test_removal_is_limited_to_obsolete_manifest_owned_files(self) -> None:
        old = self.write(LEGACY_RUST_OUTPUT)
        current = self.write("runtime/crates/spark-contracts/src/generated/mod.rs")
        unrelated = self.write("runtime/crates/spark-contracts/src/generated/unlisted.rs", "owner work\n")
        self.manifest([LEGACY_RUST_OUTPUT, str(current.relative_to(self.root))])
        removed = remove_obsolete_outputs(self.root, {str(current.relative_to(self.root))})
        self.assertEqual(removed, {LEGACY_RUST_OUTPUT})
        self.assertFalse(old.exists())
        self.assertTrue(current.exists())
        self.assertEqual(unrelated.read_text(), "owner work\n")

    def test_untracked_nested_sources_are_detected_as_stale(self) -> None:
        self.write("runtime/crates/spark-contracts/src/generated/types/n/obsolete.rs")
        with patch("check_generated_outputs.tracked_generated_outputs", return_value=set()):
            found = present_generated_outputs(self.root)
        self.assertEqual(
            stale_generated_outputs(found, set()),
            {"runtime/crates/spark-contracts/src/generated/types/n/obsolete.rs"},
        )

    def test_manifest_cannot_remove_unowned_paths(self) -> None:
        victim = self.write("runtime/crates/spark-contracts/src/lib.rs", "owner work\n")
        self.manifest([str(victim.relative_to(self.root))])
        with self.assertRaisesRegex(ValueError, "outside generator ownership"):
            remove_obsolete_outputs(self.root, set())
        self.assertEqual(victim.read_text(), "owner work\n")

    def test_removal_validates_the_entire_set_before_changing_files(self) -> None:
        old = self.write(LEGACY_RUST_OUTPUT)
        self.manifest([LEGACY_RUST_OUTPUT, "../outside.txt"])
        with self.assertRaises(ValueError):
            remove_obsolete_outputs(self.root, set())
        self.assertTrue(old.exists())

    def test_symlink_outputs_are_not_deleted(self) -> None:
        target = self.write("owner.txt", "owner work\n")
        link = self.root / LEGACY_RUST_OUTPUT
        link.parent.mkdir(parents=True)
        link.symlink_to(target)
        self.manifest([LEGACY_RUST_OUTPUT])
        with self.assertRaisesRegex(ValueError, "non-regular"):
            remove_obsolete_outputs(self.root, set())
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_text(), "owner work\n")

    def test_owned_paths_are_canonical_relative_files(self) -> None:
        for invalid in (
            "/contracts/generated/file.json",
            "contracts/generated/../../owner.txt",
            "contracts/generated",
            "contracts/generated//file.json",
            "tools/generate_openapi_clients.py",
        ):
            with self.subTest(path=invalid):
                self.assertFalse(owned_output_path(invalid))
        self.assertTrue(owned_output_path("contracts/generated/manifest.json"))


if __name__ == "__main__":
    unittest.main()
