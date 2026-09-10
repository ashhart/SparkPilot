from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from contract_yaml import DuplicateKeyError
from openapi_bundle import load_openapi_document
from openapi_codegen.model import ContractModel
from openapi_codegen.normalization import canonical_json
from openapi_codegen.rust import render_rust_files
from openapi_codegen.swift import render_swift_files


class OpenAPIBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, name: str, text: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def test_bundle_preserves_order_and_canonical_root_references(self) -> None:
        entry = self.write(
            "openapi.yaml",
            "openapi: 3.1.0\npaths:\n  $ref: paths/index.yaml\ncomponents:\n  schemas:\n    $ref: schemas/index.yaml\n",
        )
        self.write("paths/index.yaml", "/second:\n  $ref: second.yaml\n/first:\n  get: {}\n")
        self.write("paths/second.yaml", "post:\n  requestBody:\n    $ref: ../openapi.yaml#/components/schemas/Node\n")
        self.write("schemas/index.yaml", "Node:\n  type: object\n  properties:\n    z:\n      type: string\n    a:\n      $ref: ../openapi.yaml#/components/schemas/Node\n")
        expected = {
            "openapi": "3.1.0",
            "paths": {
                "/second": {"post": {"requestBody": {"$ref": "#/components/schemas/Node"}}},
                "/first": {"get": {}},
            },
            "components": {"schemas": {"Node": {
                "type": "object",
                "properties": {"z": {"type": "string"}, "a": {"$ref": "#/components/schemas/Node"}},
            }}},
        }
        self.assertEqual(
            canonical_json(load_openapi_document(entry), sort_keys=False),
            canonical_json(expected, sort_keys=False),
        )

    def test_duplicate_keys_in_a_fragment_are_rejected(self) -> None:
        entry = self.write("openapi.yaml", "$ref: fragment.yaml\n")
        self.write("fragment.yaml", "paths: {}\npaths: {}\n")
        with self.assertRaises(DuplicateKeyError):
            load_openapi_document(entry)

    def test_external_siblings_are_rejected_instead_of_discarded(self) -> None:
        entry = self.write("openapi.yaml", "$ref: fragment.yaml\nignored: true\n")
        self.write("fragment.yaml", "paths: {}\n")
        with self.assertRaisesRegex(ValueError, "sibling fields"):
            load_openapi_document(entry)

    def test_local_reference_siblings_reach_the_schema_validator_unchanged(self) -> None:
        entry = self.write("openapi.yaml", "$ref: '#/components/schemas/Node'\ndescription: retained\n")
        self.assertEqual(load_openapi_document(entry)["description"], "retained")

    def test_reference_cycles_are_rejected(self) -> None:
        entry = self.write("openapi.yaml", "$ref: fragment.yaml\n")
        self.write("fragment.yaml", "$ref: openapi.yaml\n")
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            load_openapi_document(entry)

    def test_network_references_are_not_fetched(self) -> None:
        for reference in ("https://example.invalid/schema.yaml", "//example.invalid/x", "file:///etc/passwd"):
            with self.subTest(reference=reference):
                entry = self.write("openapi.yaml", f"$ref: '{reference}'\n")
                with self.assertRaisesRegex(ValueError, "Only local"):
                    load_openapi_document(entry)

    def test_parent_directory_references_are_rejected(self) -> None:
        entry = self.write("openapi.yaml", "$ref: ../outside.yaml\n")
        with self.assertRaisesRegex(ValueError, "escapes"):
            load_openapi_document(entry)

    def test_symlink_references_cannot_escape_the_contract_directory(self) -> None:
        entry = self.write("openapi.yaml", "$ref: outside.yaml\n")
        (self.root / "outside.yaml").symlink_to(self.root.parent / "outside.yaml")
        with self.assertRaisesRegex(ValueError, "escapes"):
            load_openapi_document(entry)

    def test_json_pointer_escaping_is_preserved(self) -> None:
        entry = self.write("openapi.yaml", "$ref: fragment.yaml#/a~1b~0c\n")
        self.write("fragment.yaml", "a/b~c:\n  value: 42\n")
        self.assertEqual(load_openapi_document(entry), {"value": 42})

    def test_missing_pointer_and_file_fail(self) -> None:
        entry = self.write("openapi.yaml", "$ref: fragment.yaml#/missing\n")
        self.write("fragment.yaml", "present: {}\n")
        with self.assertRaisesRegex(ValueError, "Unresolved"):
            load_openapi_document(entry)
        entry.write_text("$ref: absent.yaml\n")
        with self.assertRaises(FileNotFoundError):
            load_openapi_document(entry)

    def test_case_insensitive_type_filename_collisions_fail(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        schema = {"type": "object", "properties": {"value": {"type": "string"}}}
        contract.register_model("URL", schema)
        contract.register_model("Url", schema)
        for render in (render_swift_files, render_rust_files):
            with self.subTest(renderer=render.__name__), self.assertRaisesRegex(ValueError, "colliding"):
                render(contract, "test")

    def test_operation_filename_collisions_fail(self) -> None:
        contract = ContractModel({
            "components": {"schemas": {}},
            "paths": {
                "/a": {"get": {"operationId": "readItem", "responses": {}}},
                "/b": {"get": {"operationId": "read_item", "responses": {}}},
            },
        })
        contract.build()
        for render in (render_swift_files, render_rust_files):
            with self.subTest(renderer=render.__name__), self.assertRaisesRegex(ValueError, "colliding"):
                render(contract, "test")

    def test_generated_sources_have_complete_bounded_type_files(self) -> None:
        contract = ContractModel(load_openapi_document(ROOT / "contracts/openapi.yaml"))
        contract.build()
        swift = render_swift_files(contract, "test")
        rust = render_rust_files(contract, "test")
        basenames = [Path(path).name.casefold() for path in swift]
        self.assertEqual(len(basenames), len(set(basenames)))
        for name, content in {**swift, **rust}.items():
            with self.subTest(file=name):
                self.assertLessEqual(len(content.splitlines()), 600)
        self.assertEqual(
            sum(name.startswith("Models/") for name in swift), len(contract.models)
        )
        self.assertEqual(
            sum(name.startswith("Operations/") for name in swift), len(contract.operations)
        )
        self.assertIn("public enum GeneratedAPI", swift["APIContract.generated.swift"])
        self.assertIn("pub use types::*;", rust["mod.rs"])
        for operation in contract.operations:
            self.assertIn(operation.operation_id, "".join(swift.values()))


if __name__ == "__main__":
    unittest.main()
