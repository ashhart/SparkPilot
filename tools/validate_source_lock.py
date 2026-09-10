#!/usr/bin/env python3
"""Validate build source-lock fields consumed by contract and CI tooling."""

from __future__ import annotations

import hashlib
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

from contract_json import load_json_strict
from contract_python import SUPPORTED_PYTHON

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def requirement_versions(path: Path) -> dict[str, str]:
    versions: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("--hash="):
            continue
        requirement = line.split(" \\", 1)[0]
        if "==" not in requirement:
            raise ValueError(f"unlocked requirement: {requirement}")
        name, version = requirement.split("==", 1)
        normalized_name = re.sub(r"[-_.]+", "-", name.lower())
        versions[normalized_name] = version
    return versions


def unhashed_requirements(path: Path) -> list[str]:
    missing: list[str] = []
    current: str | None = None
    has_hash = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line and not line.startswith(("#", "--hash=")) and "==" in line:
            if current is not None and not has_hash:
                missing.append(current)
            current = line.split("==", 1)[0]
            has_hash = False
        elif line.startswith("--hash="):
            has_hash = True
    if current is not None and not has_hash:
        missing.append(current)
    return missing


def source_lock_errors(
    root: Path = ROOT,
    *,
    lock: dict[str, Any] | None = None,
    python_version: tuple[int, int] | None = None,
) -> list[str]:
    lock = lock or load_json_strict(root / "docs/build/source-lock.json")
    errors: list[str] = []
    contract = lock["contract_generation"]
    rust = lock["rust"]

    expected_python = f"{SUPPORTED_PYTHON[0]}.{SUPPORTED_PYTHON[1]}.x"
    if contract.get("python_policy") != expected_python:
        errors.append("contract_generation.python_policy does not match tooling policy")
    actual_python = python_version or sys.version_info[:2]
    if actual_python != SUPPORTED_PYTHON:
        errors.append(
            f"contract tooling is running on {actual_python[0]}.{actual_python[1]}, "
            f"not {SUPPORTED_PYTHON[0]}.{SUPPORTED_PYTHON[1]}"
        )

    requirements = root / contract["requirements"]
    requirements_source = root / contract["requirements_source"]
    if contract.get("requirements_source_sha256") != sha256(requirements_source):
        errors.append("contract requirements source hash is stale")
    if contract.get("requirements_sha256") != sha256(requirements):
        errors.append("contract requirements hash is stale")
    missing_hashes = unhashed_requirements(requirements)
    if missing_hashes:
        errors.append(f"contract requirements lack artifact hashes: {missing_hashes}")
    versions = requirement_versions(requirements)
    if versions != requirement_versions(requirements_source):
        errors.append("hashed requirements do not match the version-pinned source")
    expected_packages = {
        "pyyaml": contract.get("yaml_parser"),
        "openapi-spec-validator": contract.get("openapi_validator"),
        "jsonschema": contract.get("jsonschema_validator"),
    }
    for name, locked_version in expected_packages.items():
        if locked_version != versions.get(name):
            errors.append(f"contract_generation {name} version is stale")

    generator = (root / contract["implementation"]).read_text(encoding="utf-8")
    format_match = re.search(
        r"^GENERATOR_FORMAT_VERSION = (\d+)$", generator, re.MULTILINE
    )
    if format_match is None or contract.get("format_version") != int(
        format_match.group(1)
    ):
        errors.append("contract_generation.format_version is stale")

    requirements_compiler = (
        root / "tools/compile-contract-requirements.sh"
    ).read_text(encoding="utf-8")
    pip_match = re.search(r'^PIP_VERSION="([^"]+)"$', requirements_compiler, re.MULTILINE)
    pip_tools_match = re.search(
        r'^PIP_TOOLS_VERSION="([^"]+)"$', requirements_compiler, re.MULTILINE
    )
    package_index_match = re.search(
        r'^PACKAGE_INDEX_URL="([^"]+)"$', requirements_compiler, re.MULTILINE
    )
    if pip_match is None or contract.get("pip") != pip_match.group(1):
        errors.append("contract_generation.pip does not match the lock compiler")
    if pip_tools_match is None or contract.get("pip_tools") != pip_tools_match.group(1):
        errors.append("contract_generation.pip_tools does not match the lock compiler")
    if (
        package_index_match is None
        or contract.get("package_index") != package_index_match.group(1)
    ):
        errors.append("contract_generation.package_index does not match the lock compiler")

    toolchain = tomllib.loads((root / "rust-toolchain.toml").read_text(encoding="utf-8"))[
        "toolchain"
    ]
    channel = toolchain["channel"]
    workspace = tomllib.loads((root / "runtime/Cargo.toml").read_text(encoding="utf-8"))
    floor = workspace["workspace"]["package"]["rust-version"]
    if rust.get("rust_version_floor") != floor:
        errors.append("rust.rust_version_floor does not match runtime/Cargo.toml")
    if tuple(map(int, floor.split("."))) != tuple(map(int, channel.split(".")[:2])):
        errors.append("the declared Rust minimum must match the tested toolchain")
    if rust.get("toolchain") != channel:
        errors.append("rust.toolchain does not match rust-toolchain.toml")
    if contract.get("rustfmt") != channel or "rustfmt" not in toolchain["components"]:
        errors.append("contract_generation.rustfmt does not match the installed toolchain")
    if rust.get("cargo_lock_sha256") != sha256(root / "runtime/Cargo.lock"):
        errors.append("rust.cargo_lock_sha256 is stale")

    contract_workflow = (root / ".github/workflows/contracts.yml").read_text(
        encoding="utf-8"
    )
    workflow_python = re.search(
        r'^\s+python-version: "([^"]+)"$', contract_workflow, re.MULTILINE
    )
    workflow_rust = re.search(
        r'^\s+toolchain: "([^"]+)"$', contract_workflow, re.MULTILINE
    )
    if workflow_python is None or workflow_python.group(1) != "3.12":
        errors.append("contract CI Python does not match the 3.12.x policy")
    if workflow_rust is None or workflow_rust.group(1) != channel:
        errors.append("contract CI Rust does not match rust-toolchain.toml")

    justfile = (root / "Justfile").read_text(encoding="utf-8")
    audit_match = re.search(r'^cargo_audit_version := "([^"]+)"$', justfile, re.MULTILINE)
    if audit_match is None or rust.get("cargo_audit") != audit_match.group(1):
        errors.append("rust.cargo_audit does not match the Justfile tool pin")
    return errors


def validate_source_lock(root: Path = ROOT) -> None:
    errors = source_lock_errors(root)
    if errors:
        raise ValueError("source-lock validation failed:\n  " + "\n  ".join(errors))


if __name__ == "__main__":
    validate_source_lock()
    print("source lock ok")
