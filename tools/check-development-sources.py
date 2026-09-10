#!/usr/bin/env python3
"""Verify the vendored terminal sources and immutable development runtime inputs."""

import hashlib
import json
from pathlib import Path
import re


def verify_terminal_sources(root, terminal):
    vendor = root / terminal["path"]
    sources = vendor / "Sources/SwiftTerm"
    hashes = json.loads((root / terminal["source_hashes"]).read_text())
    patches = terminal.get("local_source_hashes", {})
    assert set(patches) <= set(hashes), "Local terminal patch names an unknown source"
    for name, digest in patches.items():
        assert re.fullmatch(r"[0-9a-f]{64}", digest), name
        assert digest != hashes[name], "Redundant local terminal patch: " + name
    assert set(hashes) == {
        str(path.relative_to(sources))
        for path in sources.rglob("*")
        if path.is_file() and path.name != "SwiftTermBuildInfo.swift"
    }, "SwiftTerm's source inventory differs from its reviewed manifest"
    for name, digest in hashes.items():
        expected = patches.get(name, digest)
        assert hashlib.sha256((sources / name).read_bytes()).hexdigest() == expected, name
    assert terminal["revision"] in (sources / "SwiftTermBuildInfo.swift").read_text()
    assert (vendor / "LICENSE").is_file()
    assert ".plugin(" not in (vendor / "Package.swift").read_text()
    return len(hashes), len(patches)


def main():
    root = Path(__file__).resolve().parents[1]
    lock = json.loads((root / "docs/build/source-lock.json").read_text())
    count, patches = verify_terminal_sources(root, lock["swift_packages"]["swiftterm"])

    runtime = root / "runtime/crates"
    image = lock["containers"]["development"]
    reference = image["reference"] + "@" + image["digest"]
    assert re.fullmatch(r"node@sha256:[0-9a-f]{64}", reference)
    assert any(reference in p.read_text() for p in (runtime / "spark-core/src").rglob("*.rs"))
    launcher = (runtime / "sparkd/src/project_api/development-launch.cjs").read_text()
    launcher += (runtime / "sparkd/src/project_api/development-tools.cjs").read_text()
    release = json.loads(
        (runtime / "sparkd/src/project_api/harness-locks/oh_my_pi/release.json").read_text()
    )
    oh_my_pi = lock["development_harnesses"]["oh_my_pi"]
    assert release["version"] == oh_my_pi["version"], "host Oh My Pi pin drifted"
    assert release["sha256"] == oh_my_pi["sha256"], "host Oh My Pi digests drifted"
    for harness, entry in lock["development_harnesses"].items():
        assert entry["version"] in launcher, harness
        if harness == "oh_my_pi":
            for digest in entry["sha256"].values():
                assert re.fullmatch(r"[0-9a-f]{64}", digest) and digest in launcher
            continue
        manifest = json.loads((root / entry["manifest"]).read_text())
        raw = (root / entry["lock"]).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == entry["lock_sha256"], harness
        packages = json.loads(raw)["packages"]
        expected = {entry["package"]: entry["version"]}
        assert manifest["dependencies"] == packages[""]["dependencies"] == expected, harness
        for name, package in packages.items():
            if not name:
                continue
            assert package["resolved"].startswith("https://registry.npmjs.org/"), name
            assert package["integrity"].startswith("sha512-"), name
    print(
        f"Verified {count} terminal files with {patches} reviewed local patches, "
        "development image and five harness pins."
    )


if __name__ == "__main__":
    main()
