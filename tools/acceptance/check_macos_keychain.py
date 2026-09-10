#!/usr/bin/env python3
"""Check real Keychain access with a temporary probe carrying the signed app's identity and entitlements."""

import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def check(app, signing_identity):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    entitlements = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app)],
        check=True, capture_output=True,
    ).stdout
    original = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    with tempfile.TemporaryDirectory(prefix="spark-keychain-acceptance-") as directory:
        root = Path(directory)
        probe = root / "Probe.app"
        executable = probe / "Contents/MacOS/probe"
        executable.parent.mkdir(parents=True)
        profile = app / "Contents/embedded.provisionprofile"
        if profile.exists():
            shutil.copyfile(profile, probe / "Contents/embedded.provisionprofile")
        (probe / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": original["CFBundleIdentifier"],
            "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
        }))
        (root / "entitlements.plist").write_bytes(entitlements)
        subprocess.run([
            "xcrun", "swiftc", str(Path(__file__).with_name("keychain_probe.swift")),
            "-o", str(executable),
        ], check=True)
        subprocess.run([
            "codesign", "--force", "--sign", signing_identity,
            "--entitlements", str(root / "entitlements.plist"), str(probe),
        ], check=True)
        subprocess.run([str(executable)], check=True)
    print("Signed macOS Keychain access passed without creating or changing stored items")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--signing-identity", required=True)
    options = parser.parse_args()
    check(options.app, options.signing_identity)
