"""Run the postinst configuration seed against disposable files with a logging stand-in for chown."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ConfigSeedTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.conf = self.root / "etc/spark-runtime"
        self.conf.mkdir(parents=True)
        self.config = self.conf / "config.toml"
        self.example = self.conf / "config.toml.example"
        self.example.write_text("[node]\nname = \"example\"\n")
        self.log = self.root / "chown.log"
        binaries = self.root / "bin"
        binaries.mkdir()
        fake = binaries / "chown"
        fake.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$SEED_TEST_LOG"\n')
        fake.chmod(0o755)
        source = (ROOT / "packaging/debian/control/postinst").read_text()
        self.function = source.split("seed_configuration() {", 1)[1].split("\n}\n", 1)[0]
        self.function = "seed_configuration() {" + self.function + "\n}\n"
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
            SEED_TEST_LOG=str(self.log), CONFIG=str(self.config), EXAMPLE=str(self.example),
            RUNTIME_GROUP="sparkd")

    def run_seed(self):
        return subprocess.run(["sh", "-c", self.function + "\nseed_configuration"],
            env=self.environment, capture_output=True, text=True)

    def test_a_fresh_install_seeds_the_example_with_a_private_mode(self):
        result = self.run_seed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), self.example.read_text())
        self.assertEqual(stat.S_IMODE(self.config.lstat().st_mode), 0o640)
        self.assertEqual(self.log.read_text().splitlines(), [f"root:sparkd {self.config}"])

    def test_an_existing_configuration_is_left_alone(self):
        self.config.write_text("operator edits\n")
        result = self.run_seed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), "operator edits\n")
        self.assertFalse(self.log.exists())

    def test_a_link_at_the_configuration_name_is_refused_and_its_target_untouched(self):
        victim = self.root / "victim"
        victim.write_text("keep me\n")
        self.config.symlink_to(victim)
        result = self.run_seed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link", result.stderr)
        self.assertEqual(victim.read_text(), "keep me\n")
        self.assertFalse(self.log.exists())

    def test_a_dangling_link_at_the_configuration_name_is_refused(self):
        self.config.symlink_to(self.root / "nowhere")
        result = self.run_seed()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "nowhere").exists())

    def test_a_link_at_the_example_name_is_refused(self):
        self.example.unlink()
        self.example.symlink_to(self.root / "elsewhere.toml")
        (self.root / "elsewhere.toml").write_text("not the package's example\n")
        result = self.run_seed()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())

    def test_a_missing_example_seeds_nothing(self):
        self.example.unlink()
        result = self.run_seed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
