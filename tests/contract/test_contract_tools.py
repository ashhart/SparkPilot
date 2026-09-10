from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from check_generated_outputs import stale_generated_outputs, tracked_generated_outputs
from contract_json import (
    DuplicateJSONKeyError,
    load_json_strict,
    load_json_strict_text,
)
from contract_python import require_supported_python
from openapi_bundle import load_openapi_document
from contract_yaml import DuplicateKeyError, load_yaml_strict, load_yaml_strict_text
from generate_openapi_clients import (
    ContractModel,
    canonical_json,
    render_rust,
    render_swift,
)
from openapi_spec_validator import OpenAPIV31SpecValidator
from validate_source_lock import source_lock_errors
from validate_contracts import validate_mutation_idempotency


class StrictContractTests(unittest.TestCase):
    def test_live_telemetry_distinguishes_unavailable_evidence_from_zero(self) -> None:
        document = load_openapi_document(ROOT / "contracts/openapi.yaml")
        schemas = document["components"]["schemas"]

        system = schemas["TelemetrySystem"]
        for field in ("memory_psi_some_avg10", "memory_psi_full_avg10"):
            self.assertIn(field, system["required"])
            self.assertEqual(set(system["properties"][field]["type"]), {"number", "null"})

        accelerator = schemas["AcceleratorTelemetry"]
        for field in ("memory_used_bytes", "memory_total_bytes"):
            self.assertIn(field, accelerator["required"])
            self.assertEqual(
                set(accelerator["properties"][field]["type"]),
                {"integer", "null"},
            )

        queue_depth = schemas["InferenceState"]["properties"]["queue_depth"]
        self.assertEqual(set(queue_depth["type"]), {"integer", "null"})
        self.assertNotIn("default", queue_depth)

    def test_apple_build_gate_compiles_both_shipping_apps(self) -> None:
        script = (ROOT / "tools/build-apple.sh").read_text()
        self.assertRegex(
            script,
            r'-scheme Spark\s+\\\n\s+-destination "generic/platform=iOS"',
        )
        self.assertRegex(
            script,
            r'-scheme SparkMac\s+\\\n\s+-destination "generic/platform=macOS"',
        )

    def test_duplicate_mapping_key_is_rejected(self) -> None:
        with self.assertRaisesRegex(DuplicateKeyError, "duplicate YAML key 'get'"):
            load_yaml_strict_text("paths:\n  /health:\n    get: {}\n    get: {}\n")

    def test_complete_openapi_document_validates_as_31(self) -> None:
        document = load_openapi_document(ROOT / "contracts/openapi.yaml")
        self.assertEqual(list(OpenAPIV31SpecValidator(document).iter_errors()), [])

    def test_every_durable_mutation_requires_an_idempotency_key(self) -> None:
        document = load_openapi_document(ROOT / "contracts/openapi.yaml")
        validate_mutation_idempotency(document)

        broken = copy.deepcopy(document)
        broken["paths"]["/api/v1/build_workers"]["post"]["parameters"] = []
        with self.assertRaises(SystemExit):
            validate_mutation_idempotency(broken)

    def test_generated_manifest_exhaustively_covers_openapi(self) -> None:
        document = load_openapi_document(ROOT / "contracts/openapi.yaml")
        manifest = load_json_strict(ROOT / "contracts/generated/manifest.json")
        generated = {operation["id"]: operation for operation in manifest["operations"]}
        declared: dict[str, dict] = {}
        methods = {"get", "put", "post", "delete", "patch"}
        for path, path_item in document["paths"].items():
            for method, operation in path_item.items():
                if method not in methods:
                    continue
                declared[operation["operationId"]] = {
                    "path": path,
                    "method": method.upper(),
                    "operation": operation,
                    "path_parameters": path_item.get("parameters", []),
                }

        self.assertEqual(set(generated), set(declared))
        self.assertEqual(
            set(manifest["represented_component_schemas"]),
            set(document["components"]["schemas"]),
        )
        for operation_id, source in declared.items():
            binding = generated[operation_id]
            self.assertEqual(binding["path"], source["path"])
            self.assertEqual(binding["method"], source["method"])

            request_content = source["operation"].get("requestBody", {}).get("content", {})
            if request_content:
                self.assertNotEqual(binding["request_body_kind"], "none")
                if any(
                    media_type == "application/json" or media_type.endswith("+json")
                    for media_type in request_content
                ):
                    self.assertIsNotNone(binding["request_type"])

            source_parameters = [
                *source["path_parameters"],
                *source["operation"].get("parameters", []),
            ]
            self.assertEqual(len(binding["parameters"]), len(source_parameters))

            expected_responses = 0
            for response in source["operation"]["responses"].values():
                if "$ref" in response:
                    name = response["$ref"].rsplit("/", 1)[-1]
                    response = document["components"]["responses"][name]
                expected_responses += max(1, len(response.get("content", {})))
            self.assertEqual(len(binding["responses"]), expected_responses)

    def test_binary_content_produces_one_response_shape(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        shapes = contract.content_shapes(
            {
                "application/octet-stream": {
                    "schema": {"type": "string", "format": "binary"}
                }
            },
            "DownloadResponse200",
        )

        self.assertEqual(
            shapes,
            [("application/octet-stream", "binary", None)],
        )

    def test_duplicate_json_member_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            DuplicateJSONKeyError, "duplicate JSON key 'member_node_ids'"
        ):
            load_json_strict_text(
                '{"name":"lab","member_node_ids":[],"member_node_ids":[]}'
            )

    def test_unsupported_schema_compositions_fail_loudly(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        for keyword in ("allOf", "anyOf"):
            with self.subTest(keyword=keyword), self.assertRaisesRegex(
                ValueError, f"unsupported JSON Schema keyword.*{keyword}"
            ):
                contract.type_ref(
                    {keyword: [{"type": "string"}, {"type": "integer"}]},
                    "UnsupportedComposition",
                )

        with self.assertRaisesRegex(ValueError, "unsupported oneOf"):
            contract.type_ref(
                {
                    "oneOf": [
                        {"type": "string"},
                        {"type": "integer"},
                        {"type": "null"},
                    ]
                },
                "UnsupportedUnion",
            )

    def test_nullable_one_of_is_the_only_supported_union(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        resolved = contract.type_ref(
            {"oneOf": [{"type": "string"}, {"type": "null"}]},
            "NullableString",
        )
        self.assertEqual(resolved.kind, "string")
        self.assertTrue(resolved.nullable)

        with self.assertRaisesRegex(ValueError, "unsupported oneOf"):
            contract.type_ref(
                {"oneOf": [{"type": "string"}, {"type": "integer"}]},
                "NonNullableUnion",
            )

    def test_multiple_non_null_types_fail_loudly(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        with self.assertRaisesRegex(ValueError, "unsupported type array"):
            contract.type_ref(
                {"type": ["string", "integer", "null"]},
                "UnsupportedTypeUnion",
            )

    def test_top_level_component_ref_siblings_fail_before_model_registration(self) -> None:
        document = {
            "components": {
                "schemas": {
                    "Base": {
                        "type": "object",
                        "properties": {"id": {"type": "string"}},
                    },
                    "Broken": {
                        "$ref": "#/components/schemas/Base",
                        "type": "object",
                        "properties": {"extra": {"type": "string"}},
                    },
                }
            },
            "paths": {},
        }
        contract = ContractModel(document)

        with self.assertRaisesRegex(ValueError, "Broken combines \\$ref"):
            contract.build()

        self.assertNotIn("Broken", contract.models)

    def test_inline_model_name_cannot_hide_invalid_top_level_component(self) -> None:
        document = {
            "components": {
                "schemas": {
                    "A": {
                        "type": "object",
                        "properties": {
                            "b": {
                                "type": "object",
                                "properties": {"value": {"type": "string"}},
                            }
                        },
                    },
                    "AB": {
                        "$ref": "#/components/schemas/A",
                        "type": "object",
                        "properties": {"extra": {"type": "string"}},
                    },
                }
            },
            "paths": {},
        }
        contract = ContractModel(document)

        with self.assertRaisesRegex(ValueError, "AB combines \\$ref"):
            contract.build()

    def test_generated_model_name_reuses_only_identical_schema(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        schema = {
            "type": "object",
            "properties": {"value": {"type": "string"}},
        }

        contract.register_model("Repeated", schema)
        contract.register_model("Repeated", copy.deepcopy(schema))
        self.assertEqual(list(contract.models), ["Repeated"])

        with self.assertRaisesRegex(ValueError, "conflicting generated model name: Repeated"):
            contract.register_model(
                "Repeated",
                {
                    "type": "object",
                    "properties": {"value": {"type": "integer"}},
                },
            )

    def test_permissive_object_unknown_fields_are_explicitly_modelled(self) -> None:
        contract = ContractModel({"components": {"schemas": {}}})
        resolved = contract.type_ref(
            {"type": "object", "properties": {"name": {"type": "string"}}},
            "OpenObject",
        )

        self.assertEqual(resolved.kind, "model")
        self.assertEqual(
            contract.models["OpenObject"].additional_properties.kind,
            "json",
        )
        self.assertIn(
            "public var additionalProperties: [String: JSONValue]",
            render_swift(contract, "digest"),
        )
        self.assertIn("#[serde(flatten)]", render_rust(contract, "digest"))

        closed_contract = ContractModel({"components": {"schemas": {}}})
        closed_contract.type_ref(
            {
                "type": "object",
                "additionalProperties": False,
                "properties": {"name": {"type": "string"}},
            },
            "ClosedObject",
        )
        self.assertIsNone(closed_contract.models["ClosedObject"].additional_properties)

    def test_generation_identity_preserves_source_order(self) -> None:
        first = {"type": "object", "properties": {"a": {}, "b": {}}}
        reordered = {"type": "object", "properties": {"b": {}, "a": {}}}
        self.assertNotEqual(
            canonical_json(first, sort_keys=False),
            canonical_json(reordered, sort_keys=False),
        )
        self.assertEqual(canonical_json(first), canonical_json(reordered))

    def test_current_openapi_uses_only_supported_schema_shapes(self) -> None:
        document = load_openapi_document(ROOT / "contracts/openapi.yaml")
        contract = ContractModel(document)
        contract.build()
        self.assertTrue(
            set(document["components"]["schemas"]).issubset(
                set(contract.models) | set(contract.aliases) | set(contract.enums)
            )
        )

    def test_stale_tracked_generated_output_is_rejected(self) -> None:
        tracked = {
            "contracts/generated/manifest.json",
            "contracts/generated/removed.json",
            "contracts/generated/.gitkeep",
        }
        expected = {"contracts/generated/manifest.json"}
        self.assertEqual(
            stale_generated_outputs(tracked, expected),
            {"contracts/generated/removed.json"},
        )

        manifest = load_json_strict(ROOT / "contracts/generated/manifest.json")
        self.assertEqual(
            stale_generated_outputs(
                tracked_generated_outputs(ROOT), set(manifest["outputs"])
            ),
            set(),
        )

    def test_source_lock_matches_consumed_tools_and_inputs(self) -> None:
        require_supported_python()
        self.assertEqual(source_lock_errors(ROOT), [])

    def test_source_lock_rejects_stale_fields_and_wrong_python(self) -> None:
        original = load_json_strict(ROOT / "docs/build/source-lock.json")
        mutations = {
            "requirements hash": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "requirements_sha256", "sha256:stale"
                ),
                "requirements hash is stale",
            ),
            "requirements source hash": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "requirements_source_sha256", "sha256:stale"
                ),
                "requirements source hash is stale",
            ),
            "requirement version": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "yaml_parser", "0.0.0"
                ),
                "pyyaml version is stale",
            ),
            "generator format": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "format_version", 999
                ),
                "format_version is stale",
            ),
            "pip": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "pip", "0.0.0"
                ),
                "contract_generation.pip",
            ),
            "pip-tools": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "pip_tools", "0.0.0"
                ),
                "contract_generation.pip_tools",
            ),
            "package index": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "package_index", "https://example.invalid/simple"
                ),
                "contract_generation.package_index",
            ),
            "rustfmt": (
                lambda lock: lock["contract_generation"].__setitem__(
                    "rustfmt", "0.0.0"
                ),
                "contract_generation.rustfmt",
            ),
            "Rust toolchain": (
                lambda lock: lock["rust"].__setitem__("toolchain", "0.0.0"),
                "rust.toolchain",
            ),
            "Cargo lock": (
                lambda lock: lock["rust"].__setitem__(
                    "cargo_lock_sha256", "sha256:stale"
                ),
                "cargo_lock_sha256 is stale",
            ),
            "cargo-audit": (
                lambda lock: lock["rust"].__setitem__("cargo_audit", "0.0.0"),
                "cargo_audit",
            ),
        }
        for name, (mutate, expected_error) in mutations.items():
            with self.subTest(name=name):
                changed = copy.deepcopy(original)
                mutate(changed)
                self.assertTrue(
                    any(
                        expected_error in error
                        for error in source_lock_errors(ROOT, lock=changed)
                    )
                )

        self.assertTrue(
            any(
                "not 3.12" in error
                for error in source_lock_errors(
                    ROOT, lock=original, python_version=(3, 11)
                )
            )
        )


if __name__ == "__main__":
    unittest.main()
