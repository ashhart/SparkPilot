"""Run the packaged upgrade cleanup against disposable files and a scripted service manager."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RemoteRetirementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / "etc/spark-runtime"
        self.state = self.root / "var/lib/spark-runtime"
        self.log = self.root / "service.log"
        self.files = [
            "etc/systemd/system/spark-cloudflared.service",
            "usr/lib/systemd/system/spark-cloudflared.service",
            "etc/spark-runtime/cloudflared/config.yaml",
            "run/spark-runtime/cloudflared/tunnel-credentials.json",
            "var/lib/spark-runtime/remote/cloudflared-config.yaml",
            "var/lib/spark-runtime/remote/cloudflared-tunnel.json",
            "var/lib/spark-runtime/remote/encryption-key.json",
        ]
        for relative in self.files:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("test-owned retired state")
        (self.root / "run/systemd/system").mkdir(parents=True)
        self.private_state = self.state / "tailscale.json"
        self.private_state.write_text("existing private connection")
        binaries = self.root / "bin"
        binaries.mkdir()
        manager = binaries / "systemctl"
        manager.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$RETIRE_TEST_LOG"
case "$1" in
  show) printf '%s\\n' "${RETIRE_TEST_LOAD_STATE:-loaded}" ;;
  stop) exit "${RETIRE_TEST_STOP_CODE:-0}" ;;
esac
''')
        manager.chmod(0o755)
        source = (ROOT / "packaging/debian/control/postinst").read_text()
        self.function = source.split("# Upgrade-only cleanup", 1)[1].split('case "$1" in', 1)[0]
        self.function = self.function[self.function.index("retire_public_remote()") :]
        for absolute in ["/run/systemd/system", "/run/spark-runtime", "/etc/systemd/system", "/usr/lib/systemd/system"]:
            self.function = self.function.replace(absolute, str(self.root) + absolute)
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
            RETIRE_TEST_LOG=str(self.log), CONF_DIR=str(self.config), STATE_DIR=str(self.state))

    def run_cleanup(self, **environment):
        return subprocess.run(["sh", "-c", self.function + "\nretire_public_remote"],
            env=dict(self.environment, **environment), capture_output=True, text=True)

    def test_upgrade_retires_only_the_old_connector_after_stopping_it(self):
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        for relative in self.files:
            self.assertFalse((self.root / relative).exists(), relative)
        self.assertEqual(self.private_state.read_text(), "existing private connection")
        self.assertEqual(self.log.read_text().splitlines(), [
            "show --property=LoadState --value spark-cloudflared.service",
            "stop spark-cloudflared.service", "disable spark-cloudflared.service"])

    def test_stop_failure_preserves_credentials_and_fails_the_upgrade(self):
        result = self.run_cleanup(RETIRE_TEST_STOP_CODE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all((self.root / relative).exists() for relative in self.files))

    def test_redirected_state_is_refused_without_touching_its_destination(self):
        folder = self.config / "cloudflared"
        (folder / "config.yaml").unlink()
        folder.rmdir()
        outside = self.root / "unrelated"
        outside.mkdir()
        protected = outside / "config.yaml"
        protected.write_text("keep me")
        folder.symlink_to(outside, target_is_directory=True)
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(protected.read_text(), "keep me")
        self.assertFalse(self.log.exists())

    def test_missing_service_allows_idempotent_cleanup(self):
        self.assertEqual(self.run_cleanup(RETIRE_TEST_LOAD_STATE="not-found").returncode, 0)
        self.assertEqual(self.run_cleanup(RETIRE_TEST_LOAD_STATE="not-found").returncode, 0)
        self.assertNotIn("stop ", self.log.read_text())


if __name__ == "__main__":
    unittest.main()
