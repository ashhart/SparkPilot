"""Exercise the actual release CLI against the shared offline-delegation adversarial corpus."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "contracts/fixtures/release-delegation.json"
TOOL = Path(__file__).with_name("spark_release.py")


class ReleaseDelegationTests(unittest.TestCase):
    def test_cli_verifies_shared_policy_cases(self):
        fixture = json.loads(FIXTURE.read_text())
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            manifest, trust = work / "manifest.json", work / "trust.json"
            (work / "fixture.deb").write_text(fixture["package"])
            (work / "fixture.deb.sig").write_text(fixture["package_signature"])
            for case in fixture["cases"]:
                with self.subTest(case=case["name"]):
                    manifest.write_text(json.dumps(case["manifest"]))
                    trust.write_text(json.dumps(case["trust"]))
                    command = [sys.executable, str(TOOL), "verify", "--manifest", str(manifest),
                               "--trust-root", str(trust), "--at", case["at"]]
                    result = subprocess.run(command + ["--manifest-only"], capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, case["accept_manifest"], result.stderr)
                    if case["accept_manifest"]:
                        result = subprocess.run(command, capture_output=True, text=True)
                        self.assertEqual(result.returncode == 0, case["accept_package"], result.stderr)

    def test_offline_command_reproduces_public_fixture(self):
        fixture = json.loads(FIXTURE.read_text())
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            seed, root, keys = work / "root.ed25519", work / "root.json", work / "keys.json"
            seed.write_bytes(bytes([31]) * 32)
            seed.chmod(0o600)
            root.write_text(json.dumps(dict(schema=1, keys=fixture["trust"]["root_keys"])))
            keys.write_text(json.dumps(dict(schema=1, keys=fixture["trust"]["keys"])))
            command = [sys.executable, str(TOOL), "delegate", "--root-key", str(seed),
                       "--root-record", str(root), "--online-keys", str(keys), "--version", "1",
                       "--not-before", "2026-01-01T00:00:00Z", "--not-after", "2027-01-01T00:00:00Z"]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), fixture["trust"])
            seed.write_bytes(bytes([33]) * 32)
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
