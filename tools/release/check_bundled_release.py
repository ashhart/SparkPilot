#!/usr/bin/env python3
"""Verify the signed runtime bytes in an Apple build product after Xcode copies resources."""

import argparse
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

MAXIMUM_BYTES = 256 * 1024 * 1024


def verify_bundle(bundle):
    manifests = list(bundle.rglob("spark-runtime-*.json"))
    roots = list(bundle.rglob("release-keys.json"))
    if len(manifests) != 1 or len(roots) != 1:
        raise ValueError("expected exactly one bundled release manifest and trust document")
    manifest = manifests[0]
    artifacts = json.loads(manifest.read_text())["artifacts"]
    if len(artifacts) != 1:
        raise ValueError("expected one embedded runtime artifact")
    artifact = artifacts[0]
    name = artifact["name"]
    if Path(name).name != name or not name.endswith(".deb"):
        raise ValueError("invalid bundled artifact name")
    encoded = manifest.parent / (name + ".b64")
    if encoded.stat().st_size > ((MAXIMUM_BYTES + 2) // 3) * 4:
        raise ValueError("encoded package exceeds the bootstrap limit")
    if list(manifest.parent.glob("*.deb")) or len(list(manifest.parent.glob("*.deb.b64"))) != 1:
        raise ValueError("unexpected additional runtime packages")
    data = base64.b64decode(encoded.read_bytes(), validate=True)
    if len(data) != artifact["size"] or len(data) > MAXIMUM_BYTES:
        raise ValueError("decoded artifact size differs from the signed manifest")
    with tempfile.TemporaryDirectory(prefix="spark-bundle-check-") as directory:
        decoded = Path(directory) / name
        decoded.write_bytes(data)
        decoded.with_suffix(".deb.sig").write_bytes(
            (manifest.parent / (name + ".sig")).read_bytes()
        )
        subprocess.run([
            sys.executable, str(Path(__file__).with_name("spark_release.py")), "verify",
            "--manifest", str(manifest), "--trust-root", str(roots[0]),
            "--artifact-dir", directory,
        ], check=True)
    print(f"embedded runtime preserved: {name}, {len(data)} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    verify_bundle(parser.parse_args().bundle)
