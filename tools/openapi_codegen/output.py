"""Build and format every owned contract artifact before publication."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

from contract_json import load_json_strict
from openapi_bundle import load_openapi_document
from .model import ContractModel, HTTP_METHODS
from .normalization import canonical_json
from .rust import render_rust_files
from .swift import render_swift_files


def build_outputs(root: Path, format_version: int) -> dict[str, str | bytes]:
    document = load_openapi_document(root / "contracts/openapi.yaml")
    normalized = canonical_json(document)
    # The generation identity includes declaration order; normalization remains key-sorted.
    generation_input = canonical_json(document, sort_keys=False)
    digest = hashlib.sha256(generation_input).hexdigest()
    contract = ContractModel(document)
    contract.build()

    component_schemas = set(document["components"]["schemas"])
    represented_schemas = set(contract.models) | set(contract.aliases) | set(contract.enums)
    missing_schemas = component_schemas - represented_schemas
    if missing_schemas:
        raise ValueError(f"unrepresented component schemas: {sorted(missing_schemas)}")

    source_response_count = sum(
        sum(
            max(
                1,
                len(
                    contract.resolve_response(response).get("content", {})
                ),
            )
            for response in operation["responses"].values()
        )
        for path_item in document["paths"].values()
        for method in HTTP_METHODS
        if (operation := path_item.get(method)) is not None
    )
    generated_response_count = sum(len(operation.responses) for operation in contract.operations)
    if generated_response_count != source_response_count:
        raise ValueError(
            f"response coverage mismatch: {generated_response_count} generated, "
            f"{source_response_count} declared"
        )

    outputs: dict[str, str | bytes] = {
        "contracts/generated/openapi.normalized.json": normalized,
        **{
            f"apple/Packages/SparkAPI/Sources/SparkAPI/Generated/{path}": content
            for path, content in render_swift_files(contract, digest).items()
        },
        **{
            f"runtime/crates/spark-contracts/src/generated/{path}": content
            for path, content in render_rust_files(contract, digest).items()
        },
    }
    golden_root = root / "contracts/golden/requests"
    for golden in sorted(golden_root.glob("*.json")):
        canonical = canonical_json(load_json_strict(golden))
        outputs[f"apple/Packages/SparkAPI/Tests/SparkAPITests/Fixtures/{golden.name}"] = canonical
        outputs[f"runtime/crates/spark-contracts/tests/fixtures/{golden.name}"] = canonical

    manifest = {
        "format_version": format_version,
        "openapi_sha256": f"sha256:{digest}",
        "operation_count": len(contract.operations),
        "component_schema_count": len(component_schemas),
        "represented_component_schemas": sorted(component_schemas),
        "generated_model_count": len(contract.models),
        "generated_alias_count": len(contract.aliases),
        "generated_enum_count": len(contract.enums),
        "response_shape_count": generated_response_count,
        "operations": [
            {
                "id": operation.operation_id,
                "method": operation.method,
                "path": operation.path,
                "request_body_kind": operation.request_kind,
                "request_type": operation.request_type,
                "parameter_type": operation.parameter_type,
                "parameters": [
                    {
                        "name": parameter.name,
                        "in": parameter.location,
                        "required": parameter.required,
                    }
                    for parameter in operation.parameters
                ],
                "responses": [
                    {
                        "status": response.status,
                        "media_type": response.media_type,
                        "content_kind": response.content_kind,
                        "type": response.type_name,
                    }
                    for response in operation.responses
                ],
            }
            for operation in contract.operations
        ],
        "outputs": sorted([*outputs, "contracts/generated/manifest.json"]),
    }
    outputs["contracts/generated/manifest.json"] = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    return outputs


def write(root: Path, relative: str, content: str | bytes) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, str):
        content = content.encode()
    path.write_bytes(content)



def generate(root: Path, output_root: Path, format_version: int) -> None:
    outputs = build_outputs(root, format_version)
    for path, content in outputs.items():
        write(output_root, path, content)
    subprocess.run(
        ["rustfmt", "--edition", "2024", str(output_root / "runtime/crates/spark-contracts/src/generated/mod.rs")],
        check=True,
    )
    for relative in outputs:
        if Path(relative).suffix not in {".swift", ".rs"}:
            continue
        count = len((output_root / relative).read_text(encoding="utf-8").splitlines())
        if count > 600:
            raise ValueError(f"{relative} has {count} lines; extract a type responsibility before generation")
