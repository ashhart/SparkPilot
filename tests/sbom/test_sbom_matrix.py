"""Validate deterministic lockfile-derived CycloneDX output offline with the pinned contract tools."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import re
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = Path(__file__).resolve().parent / "schema"
#: Verify the provenance hash before validation so schema edits cannot silently weaken the gate.
SCHEMA_HASHES = {
    "bom-1.5.schema.json": (
        "067f7824b08653839ea050ae9e09ca48375eadc2652b0e2a299476e7db90335b"
    ),
    "spdx.schema.json": (
        "4f6e2b05c05d26a4f2dc5879fbc2fca94b0a28db46289d0c51345621b71cfbfc"
    ),
}
GENERATOR = ROOT / "tools/generate_sbom.py"
SBOM = ROOT / "docs/build/sbom.cdx.json"
CARGO_LOCK = ROOT / "runtime/Cargo.lock"

sys.path.insert(0, str(ROOT / "tools"))

import jsonschema  # noqa: E402
from referencing import Registry, Resource  # noqa: E402
from referencing.jsonschema import DRAFT7  # noqa: E402

import generate_sbom  # noqa: E402


@contextlib.contextmanager
def patched(**attributes: object):
    """Point the generator at other inputs for one assertion."""
    previous = {name: getattr(generate_sbom, name) for name in attributes}
    for name, value in attributes.items():
        setattr(generate_sbom, name, value)
    try:
        yield
    finally:
        for name, value in previous.items():
            setattr(generate_sbom, name, value)


def run_check() -> int:
    """`--check`'s exit code, which is what CI acts on."""
    argv = sys.argv
    sys.argv = ["generate_sbom.py", "--check"]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return generate_sbom.main()
    finally:
        sys.argv = argv


class SbomMatrix(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        cls.document = json.loads(SBOM.read_text(encoding="utf-8"))

    def test_the_committed_artefact_matches_the_lockfiles(self) -> None:
        self.assertEqual(run_check(), 0, "the committed SBOM is not what --check builds")

    def test_the_vendored_schemas_are_the_official_ones(self) -> None:
        for name, expected in SCHEMA_HASHES.items():
            digest = hashlib.sha256((SCHEMA_DIR / name).read_bytes()).hexdigest()
            self.assertEqual(digest, expected, f"{name} is not the vendored original")

    def test_the_document_validates_against_the_official_schema(self) -> None:
        """Validate against the vendored CycloneDX 1.5 and SPDX schemas without network retrieval."""
        schema = json.loads(
            (SCHEMA_DIR / "bom-1.5.schema.json").read_text(encoding="utf-8")
        )
        spdx = json.loads((SCHEMA_DIR / "spdx.schema.json").read_text(encoding="utf-8"))
        # Register both SPDX reference spellings locally; unregistered references must fail without network access.
        resource = Resource.from_contents(spdx, default_specification=DRAFT7)
        registry = Registry().with_resources(
            [
                ("http://cyclonedx.org/schema/spdx.schema.json", resource),
                ("spdx.schema.json", resource),
            ]
        )
        validator = jsonschema.Draft7Validator(schema, registry=registry)
        errors = sorted(validator.iter_errors(self.document), key=lambda e: e.path)
        self.assertEqual(
            [f"{list(error.path)}: {error.message}" for error in errors[:5]],
            [],
            "the SBOM is not valid CycloneDX 1.5",
        )

    def test_every_dependency_reference_resolves_to_a_component(self) -> None:
        references = {
            component["bom-ref"] for component in self.document["components"]
        }
        self.assertEqual(
            len(references), len(self.document["components"]), "a bom-ref is repeated"
        )
        for entry in self.document["dependencies"]:
            self.assertIn(entry["ref"], references, entry["ref"])
            for dependency in entry["dependsOn"]:
                self.assertIn(dependency, references, dependency)

    def test_the_document_carries_nothing_that_varies_by_machine_or_moment(self) -> None:
        """A timestamp or a home directory would make every run a diff."""
        raw = SBOM.read_text(encoding="utf-8")
        for leak in [str(ROOT), str(Path.home()), "/Users/", "/home/"]:
            self.assertNotIn(leak, raw, f"the SBOM carries {leak!r}")
        # Reject timestamp-shaped strings in any field so regeneration remains deterministic.
        self.assertIsNone(
            re.search(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}", raw),
            "the SBOM carries a timestamp",
        )
        self.assertNotIn("serialNumber", self.document)
        self.assertNotIn("timestamp", self.document["metadata"])

    def test_generating_twice_produces_the_same_bytes(self) -> None:
        self.assertEqual(generate_sbom.render(), generate_sbom.render())
        self.assertEqual(generate_sbom.render(), SBOM.read_text(encoding="utf-8"))

    def test_a_lockfile_change_without_a_refresh_fails_the_check(self) -> None:
        """Reject dependency changes that have no regenerated SBOM."""
        with tempfile.TemporaryDirectory() as scratch:
            drifted = Path(scratch) / "Cargo.lock"
            drifted.write_text(
                CARGO_LOCK.read_text(encoding="utf-8")
                + '\n[[package]]\nname = "sbom-drift-canary"\nversion = "9.9.9"\n'
                + 'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
                + 'checksum = "' + "0" * 64 + '"\n',
                encoding="utf-8",
            )
            with patched(CARGO_LOCK=drifted):
                self.assertIn("sbom-drift-canary", generate_sbom.render())
                self.assertEqual(run_check(), 1, "an added crate passed --check")
        # Restoring the reviewed lockfile must restore a passing drift check.
        self.assertEqual(run_check(), 0)

    def test_a_swift_pin_change_without_a_refresh_fails_the_check(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            moved = Path(scratch) / "Package.resolved"
            document = json.loads(
                (ROOT / "apple/Packages/SparkBootstrap/Package.resolved").read_text(
                    encoding="utf-8"
                )
            )
            document["pins"][0]["state"]["version"] = "99.0.0"
            moved.write_text(json.dumps(document, indent=2), encoding="utf-8")
            # Absolute paths select a scratch dependency graph without changing the generator root.
            with patched(PACKAGE_RESOLVED=(str(moved),)):
                self.assertIn("@99.0.0", generate_sbom.render())
                self.assertEqual(run_check(), 1, "a moved pin passed --check")
        self.assertEqual(run_check(), 0)

    def test_every_lockfile_crate_is_a_component(self) -> None:
        lock = tomllib.loads(CARGO_LOCK.read_text(encoding="utf-8"))
        # Percent-encode the purl version because a literal plus sign changes its meaning.
        expected = {
            f"pkg:cargo/{quote(package['name'], safe='')}"
            f"@{quote(package['version'], safe='')}"
            for package in lock["package"]
        }
        actual = {
            component["purl"]
            for component in self.document["components"]
            if component["purl"].startswith("pkg:cargo/")
        }
        self.assertEqual(expected, actual)

    def test_a_version_with_build_metadata_is_encoded(self) -> None:
        """Percent-encode version punctuation in purls."""
        encoded = [
            component["purl"]
            for component in self.document["components"]
            if "%2B" in component["purl"]
        ]
        self.assertTrue(encoded, "the fixture no longer has a `+` in any version")
        for purl in encoded:
            self.assertNotIn("+", purl, purl)

    def test_a_crate_pinned_at_several_versions_stays_several_components(self) -> None:
        """Retain every crate version so vulnerability checks can distinguish duplicate package names."""
        lock = tomllib.loads(CARGO_LOCK.read_text(encoding="utf-8"))
        counts: dict[str, set[str]] = {}
        for package in lock["package"]:
            counts.setdefault(package["name"], set()).add(package["version"])
        conflicted = {
            name: versions for name, versions in counts.items() if len(versions) > 1
        }
        self.assertTrue(conflicted, "the fixture no longer has a version conflict")
        for name, versions in conflicted.items():
            present = {
                component["version"]
                for component in self.document["components"]
                if component["name"] == name and component["purl"].startswith("pkg:cargo/")
            }
            self.assertEqual(present, versions, f"{name} lost a version")

    def test_an_ambiguous_dependency_is_refused_rather_than_guessed(self) -> None:
        with self.assertRaises(generate_sbom.AmbiguousDependency):
            generate_sbom.resolve(
                "rand", {}, {"rand": ["0.8.8", "0.9.5", "0.10.2"]}
            )
        self.assertEqual(
            generate_sbom.resolve(
                "rand 0.9.5",
                {("rand", "0.9.5"): "pkg:cargo/rand@0.9.5"},
                {"rand": ["0.8.8", "0.9.5"]},
            ),
            "pkg:cargo/rand@0.9.5",
        )

    def test_the_same_swift_pin_in_four_graphs_is_one_component(self) -> None:
        """All four graphs pin the same revisions, so they collapse."""
        swift = [
            component
            for component in self.document["components"]
            if component["purl"].startswith("pkg:swift/")
        ]
        identities = [component["name"] for component in swift]
        self.assertEqual(
            len(identities), len(set(identities)), "a Swift package is listed twice"
        )
        self.assertTrue(swift, "no Swift packages reached the SBOM")
        for component in swift:
            self.assertNotIn("revision=", component["purl"], component["name"])
            self.assertIn("#", component["bom-ref"], component["name"])

    def test_a_swift_package_pinned_differently_in_two_graphs_stays_two_components(
        self,
    ) -> None:
        """Keep conflicting revisions of the same package as separate components."""
        source = json.loads(
            (ROOT / "apple/Packages/SparkBootstrap/Package.resolved").read_text(
                encoding="utf-8"
            )
        )
        first = source["pins"][0]
        name = first["identity"]
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            (scratch / "a.resolved").write_text(json.dumps(source), encoding="utf-8")
            conflicting = dict(source)
            pin = json.loads(json.dumps(first))
            # Hold package and version constant to isolate the revision collision that a purl cannot distinguish.
            pin["state"]["revision"] = "f" * 40
            conflicting["pins"] = [pin]
            (scratch / "b.resolved").write_text(
                json.dumps(conflicting), encoding="utf-8"
            )
            with patched(
                PACKAGE_RESOLVED=(
                    str(scratch / "a.resolved"),
                    str(scratch / "b.resolved"),
                )
            ):
                components = generate_sbom.swift_components()
        matching = [
            component for component in components if component["name"] == name
        ]
        self.assertEqual(
            len(matching), 2, f"{name} pinned two ways collapsed into one component"
        )
        self.assertEqual(
            len({component["purl"] for component in matching}),
            1,
            "the purls differ, so this is not the same-version case",
        )
        self.assertEqual(
            len({component["bom-ref"] for component in matching}),
            2,
            "two revisions share a bom-ref, so one hides the other",
        )
        self.assertEqual(
            {
                component["properties"][0]["value"]
                for component in matching
            },
            {first["state"]["revision"], "f" * 40},
            "the revisions are not both recorded",
        )

    def test_every_swift_purl_names_its_source_host_and_owner(self) -> None:
        """Swift purls require the source host and owner namespace."""
        swift = [
            component
            for component in self.document["components"]
            if component["purl"].startswith("pkg:swift/")
        ]
        self.assertTrue(swift)
        for component in swift:
            path = component["purl"].removeprefix("pkg:swift/").split("@", 1)[0]
            self.assertGreaterEqual(
                len(path.split("/")), 3, f"{component['purl']} has no host and owner"
            )
            self.assertIn(".", path.split("/")[0], "the namespace is not a host")
            self.assertFalse(path.endswith(".git"), component["purl"])

    def test_a_source_location_this_cannot_parse_is_refused(self) -> None:
        for location in [
            "git@github.com:apple/swift-nio.git",
            "http://github.com/apple/swift-nio.git",
            "https://github.com",
            "file:///tmp/local-checkout",
        ]:
            with self.subTest(location=location):
                with self.assertRaises(generate_sbom.UnsupportedSource):
                    generate_sbom.swift_purl(location)
        self.assertEqual(
            generate_sbom.swift_purl("https://github.com/apple/swift-nio.git"),
            "github.com/apple/swift-nio",
        )

    def test_a_dependency_that_resolves_to_no_component_is_refused(self) -> None:
        """The generator validates its own graph before writing it."""
        real = generate_sbom.cargo_components

        def broken() -> tuple[list, dict]:
            components, graph = real()
            graph[components[0]["bom-ref"]] = ["pkg:cargo/not-in-this-lockfile@1.0.0"]
            return components, graph

        with patched(cargo_components=broken):
            with self.assertRaises(ValueError):
                generate_sbom.document()

    def test_retired_remote_components_are_absent(self) -> None:
        names = {component["name"] for component in self.document["components"]}
        self.assertNotIn("spark-relay-worker", names)
        self.assertNotIn("rsa", names)

    def test_every_committed_swift_graph_is_read(self) -> None:
        """Discover added resolved graphs so their dependencies cannot be omitted."""
        paths = subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=ROOT,
        ).decode().split("\0")
        found = {path for path in paths if Path(path).name == "Package.resolved"}
        self.assertEqual(found, set(generate_sbom.PACKAGE_RESOLVED))


if __name__ == "__main__":
    unittest.main()
