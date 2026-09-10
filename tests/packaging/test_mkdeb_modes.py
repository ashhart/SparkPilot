"""Build a package from a staged tree with mixed source modes and read back what mkdeb recorded for each member."""
import io
import lzma
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MKDEB = ROOT / "packaging/debian/mkdeb.py"


def ar_members(package: bytes) -> dict[str, bytes]:
    """Parse the ar container: a global header, then 60-byte member headers with even-padded payloads."""
    assert package.startswith(b"!<arch>\n")
    members = {}
    offset = 8
    while offset < len(package):
        header = package[offset : offset + 60]
        name = header[:16].decode("ascii").rstrip()
        size = int(header[48:58].decode("ascii").strip())
        payload = package[offset + 60 : offset + 60 + size]
        members[name] = payload
        offset += 60 + size + (size % 2)
    return members


def tar_modes(compressed: bytes) -> dict[str, int]:
    with tarfile.open(fileobj=io.BytesIO(lzma.decompress(compressed)), mode="r:") as archive:
        return {member.name: member.mode & 0o7777 for member in archive.getmembers()}


class MkdebModeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.staged = root / "staged"
        self.control = root / "control"
        self.output = root / "out/test.deb"
        (self.control).mkdir()
        (self.control / "control.in").write_text(
            "Package: spark-test\nVersion: @VERSION@\nArchitecture: @ARCHITECTURE@\n"
            "Installed-Size: @INSTALLED_SIZE@\nMaintainer: test\nDescription: test\n"
        )
        (self.control / "postinst").write_text("#!/bin/sh\nexit 0\n")
        self.cases = {
            "usr/lib/spark/ordinary": (0o644, 0o644),
            "usr/lib/spark/group-writable-checkout": (0o664, 0o644),
            "usr/lib/spark/read-only-checkout": (0o444, 0o644),
            "usr/lib/spark/owner-only": (0o600, 0o600),
            "usr/lib/spark/group-readable": (0o640, 0o640),
            "usr/lib/spark/executable": (0o755, 0o755),
            "usr/lib/spark/group-writable-executable": (0o775, 0o755),
            "usr/lib/spark/owner-only-executable": (0o700, 0o700),
            "usr/lib/spark/setuid-executable": (0o4755, 0o755),
        }
        for relative, (source_mode, _) in self.cases.items():
            path = self.staged / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"payload")
            os.chmod(path, source_mode)
        private = self.staged / "etc/spark/private"
        private.mkdir(parents=True)
        (private / "keep").write_bytes(b"x")
        os.chmod(private, 0o700)

    def build(self) -> dict[str, bytes]:
        subprocess.run(
            [sys.executable, str(MKDEB), "--root", str(self.staged), "--control", str(self.control),
             "--output", str(self.output), "--version", "0.0.1", "--architecture", "arm64", "--mtime", "0"],
            check=True, capture_output=True, text=True)
        return ar_members(self.output.read_bytes())

    def test_restrictive_source_modes_survive_and_permissive_ones_are_normalised(self):
        modes = tar_modes(self.build()["data.tar.xz"])
        for relative, (source_mode, expected) in self.cases.items():
            self.assertEqual(modes["./" + relative], expected, f"{relative} staged as {source_mode:o}")
        self.assertEqual(modes["./etc/spark/private"], 0o700)
        self.assertEqual(modes["./usr/lib/spark"], 0o755)
        for name, mode in modes.items():
            self.assertFalse(mode & 0o022, f"{name} is group- or world-writable: {mode:o}")
            self.assertFalse(mode & 0o6000, f"{name} carries a setuid or setgid bit: {mode:o}")

    def test_control_members_keep_their_fixed_modes(self):
        modes = tar_modes(self.build()["control.tar.xz"])
        self.assertEqual(modes["./postinst"], 0o755)
        self.assertEqual(modes["./control"], 0o644)
        self.assertEqual(modes["./md5sums"], 0o644)


if __name__ == "__main__":
    unittest.main()
