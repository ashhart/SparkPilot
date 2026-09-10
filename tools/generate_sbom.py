#!/usr/bin/env python3
"""Generate deterministic CycloneDX output from committed lockfiles without network resolution."""

from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SBOM = ROOT / "docs/build/sbom.cdx.json"
CARGO_LOCK = ROOT / "runtime/Cargo.lock"
SPEC_VERSION = "1.5"
SCHEMA = "http://cyclonedx.org/schema/bom-1.5.schema.json"

PACKAGE_RESOLVED = (
    "apple/SparkApp/Package.resolved",
    "apple/SparkApp/SparkApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "apple/Spark.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "apple/Packages/SparkBootstrap/Package.resolved",
)

class AmbiguousDependency(Exception):
    """A lockfile dependency that names no single package."""


class UnsupportedSource(Exception):
    """A pin with no unambiguous package URL representation."""


def swift_purl(location: str) -> str:
    """Require a parseable source host and owner for the registered Swift purl namespace."""
    parts = urlsplit(location)
    if parts.scheme != "https" or not parts.hostname:
        raise UnsupportedSource(f"{location} is not an https source location")
    segments = [segment for segment in parts.path.split("/") if segment]
    if len(segments) < 2:
        raise UnsupportedSource(f"{location} names no owner and repository")
    *owner, repository = segments
    repository = repository.removesuffix(".git")
    namespace = "/".join([parts.hostname, *owner])
    return f"{quote(namespace, safe='/')}/{quote(repository, safe='')}"


def cargo_components() -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
    """Index Cargo dependencies by name and version so concurrent versions remain distinct."""
    lock = tomllib.loads(CARGO_LOCK.read_text(encoding="utf-8"))
    by_key: dict[tuple[str, str], str] = {}
    versions: dict[str, list[str]] = {}
    components: list[dict[str, Any]] = []
    graph: dict[str, list[str]] = {}
    for package in lock.get("package", []):
        name, version = package["name"], package["version"]
        reference = f"pkg:cargo/{quote(name, safe='')}@{quote(version, safe='')}"
        by_key[(name, version)] = reference
        versions.setdefault(name, []).append(version)
        component: dict[str, Any] = {
            "type": "library",
            "bom-ref": reference,
            "name": name,
            "version": version,
            "purl": reference,
        }
        if "source" not in package:
            component["type"] = "application"
            component["description"] = "First-party crate in this repository."
        if "checksum" in package:
            component["hashes"] = [{"alg": "SHA-256", "content": package["checksum"]}]
        components.append(component)
    for package in lock.get("package", []):
        reference = by_key[(package["name"], package["version"])]
        graph[reference] = sorted(
            {
                resolve(dependency, by_key, versions)
                for dependency in package.get("dependencies", [])
            }
        )
    return components, graph


def resolve(
    dependency: str,
    by_key: dict[tuple[str, str], str],
    versions: dict[str, list[str]],
) -> str:
    """One lockfile dependency string to exactly one component reference."""
    name, _, version = dependency.partition(" ")
    if version:
        return by_key[(name, version)]
    resolved = versions.get(name, [])
    if len(resolved) != 1:
        raise AmbiguousDependency(
            f"{name!r} is pinned at {len(resolved)} versions and the lockfile "
            f"did not say which one this dependency means"
        )
    return by_key[(name, resolved[0])]


def swift_components() -> list[dict[str, Any]]:
    """Include each resolved Swift revision in its bom-ref so conflicting graphs remain distinct."""
    seen: dict[str, dict[str, Any]] = {}
    for relative in PACKAGE_RESOLVED:
        document = json.loads((ROOT / relative).read_text(encoding="utf-8"))
        for pin in document.get("pins", []):
            state = pin.get("state", {})
            version = state.get("version") or state.get("branch") or "unversioned"
            revision = state.get("revision", "")
            purl = f"pkg:swift/{swift_purl(pin['location'])}@{quote(version, safe='')}"
            reference = f"{purl}#{revision}" if revision else purl
            component = {
                "type": "library",
                "bom-ref": reference,
                "name": pin["identity"],
                "version": version,
                "purl": purl,
                "externalReferences": [{"type": "vcs", "url": pin["location"]}],
            }
            if revision:
                component["properties"] = [{"name": "spark:revision", "value": revision}]
            seen.setdefault(reference, component)
    return list(seen.values())


def document() -> dict[str, Any]:
    cargo, graph = cargo_components()
    components = cargo + swift_components()
    components.sort(key=lambda component: component["bom-ref"])
    known = {component["bom-ref"] for component in components}
    if len(known) != len(components):
        raise ValueError("two components share a bom-ref")
    dependencies = sorted(
        ({"ref": reference, "dependsOn": depends} for reference, depends in graph.items()),
        key=lambda entry: entry["ref"],
    )
    for entry in dependencies:
        for reference in [entry["ref"], *entry["dependsOn"]]:
            if reference not in known:
                raise ValueError(f"dependency {reference} resolves to no component")
    return {
        "$schema": SCHEMA,
        "bomFormat": "CycloneDX",
        "specVersion": SPEC_VERSION,
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": "sparkpilot",
                "name": "SparkPilot",
                "description": (
                    "Generated offline from the committed lockfiles by "
                    "tools/generate_sbom.py."
                ),
            }
        },
        "components": components,
        "dependencies": dependencies,
    }


def render() -> str:
    return json.dumps(document(), indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the committed SBOM is not what this run produces",
    )
    rendered = render()
    if not parser.parse_args().check:
        SBOM.parent.mkdir(parents=True, exist_ok=True)
        SBOM.write_text(rendered, encoding="utf-8")
        print(f"wrote {SBOM.relative_to(ROOT)}")
        return 0
    if not SBOM.exists():
        print(f"{SBOM.relative_to(ROOT)} is missing; run tools/generate_sbom.py")
        return 1
    if SBOM.read_text(encoding="utf-8") != rendered:
        print(
            f"{SBOM.relative_to(ROOT)} does not match the lockfiles; "
            "run tools/generate_sbom.py and commit the result"
        )
        return 1
    print(f"{SBOM.relative_to(ROOT)} matches the committed lockfiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
