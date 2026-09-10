#!/usr/bin/env python3
"""Detect stale contract artifacts and remove only obsolete manifest-owned files."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path, PurePosixPath

from contract_json import load_json_strict

ROOT = Path(__file__).resolve().parents[1]
GENERATED_PATHS = (
    "contracts/generated/*",
    "apple/Packages/SparkAPI/Sources/SparkAPI/Generated/*",
    "apple/Packages/SparkAPI/Tests/SparkAPITests/Fixtures/*",
    "runtime/crates/spark-contracts/src/generated.rs",
    "runtime/crates/spark-contracts/src/generated/*",
    "runtime/crates/spark-contracts/tests/fixtures/*",
)
GENERATED_SENTINELS = {"contracts/generated/.gitkeep"}
GENERATED_DIRECTORIES = tuple(pattern.removesuffix("/*") for pattern in GENERATED_PATHS if pattern.endswith("/*"))
LEGACY_RUST_OUTPUT = "runtime/crates/spark-contracts/src/generated.rs"


def stale_generated_outputs(tracked: set[str], expected: set[str]) -> set[str]:
    return tracked - expected - GENERATED_SENTINELS


def owned_output_path(value: str) -> bool:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) != value:
        return False
    return value == LEGACY_RUST_OUTPUT or any(
        path.is_relative_to(directory) and path != PurePosixPath(directory)
        for directory in GENERATED_DIRECTORIES
    )


def tracked_generated_outputs(root: Path = ROOT) -> set[str]:
    result = subprocess.run(
        ["git", "ls-files", "--", *GENERATED_PATHS],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return {line for line in result.stdout.splitlines() if line and (root / line).exists()}


def present_generated_outputs(root: Path = ROOT) -> set[str]:
    outputs = tracked_generated_outputs(root)
    for relative in GENERATED_DIRECTORIES:
        directory = root / relative
        if directory.exists():
            outputs.update(str(path.relative_to(root)) for path in directory.rglob("*") if path.is_file() or path.is_symlink())
    if (root / LEGACY_RUST_OUTPUT).exists():
        outputs.add(LEGACY_RUST_OUTPUT)
    return outputs


def remove_obsolete_outputs(root: Path, expected: set[str]) -> set[str]:
    manifest = root / "contracts/generated/manifest.json"
    if not manifest.exists():
        return set()
    previous = set(load_json_strict(manifest)["outputs"])
    obsolete = stale_generated_outputs(previous, expected)
    for relative in obsolete:
        path = root / relative
        if not owned_output_path(relative) or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Refusing to remove an output outside generator ownership: {relative}")
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ValueError(f"Refusing to remove a non-regular generated output: {relative}")
    for relative in sorted(obsolete):
        (root / relative).unlink(missing_ok=True)
    return obsolete


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--remove-obsolete", action="store_true")
    args = parser.parse_args()
    expected = set(load_json_strict(args.manifest)["outputs"])
    if any(not owned_output_path(path) for path in expected):
        raise ValueError("Generated manifest includes an unowned output path")
    if args.remove_obsolete:
        for path in sorted(remove_obsolete_outputs(ROOT, expected)):
            print(f"removed obsolete generated output: {path}")
        return
    stale = stale_generated_outputs(present_generated_outputs(), expected)
    if stale:
        for path in sorted(stale):
            print(f"stale generated output: {path}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
