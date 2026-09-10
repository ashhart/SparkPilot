#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import OpenAPIV31SpecValidator

from contract_json import load_json_strict
from contract_python import require_supported_python
from contract_yaml import DuplicateKeyError, load_yaml_strict
from openapi_bundle import load_openapi_document
from runtime_schema import load_runtime_schema
from validate_source_lock import validate_source_lock
from release.release_delegation import validate_trust
from release.spark_release import canonical_bytes

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_json_schemas() -> None:
    schema_dir = ROOT / "contracts" / "schemas"
    schemas: dict[str, dict] = {}
    for path in sorted(schema_dir.glob("*.json")):
        schema = load_json_strict(path)
        Draft202012Validator.check_schema(schema)
        schemas[path.name] = schema
        print(f"schema ok: {path.relative_to(ROOT)}")

    invite = load_json_strict(ROOT / "contracts/examples/pairing-invite.json")
    Draft202012Validator(
        schemas["pairing-invite.schema.json"],
        format_checker=FormatChecker(),
    ).validate(invite)
    print("example ok: contracts/examples/pairing-invite.json")

    recipe_paths = sorted((ROOT / "recipes").glob("*.yaml")) + sorted(
        (ROOT / "recipes").glob("*.json")
    )
    for path in recipe_paths:
        recipe = load_yaml_strict(path)
        schema_name = {
            "ModelRecipe": "model-recipe.schema.json",
            "ServiceRecipe": "service-recipe.schema.json",
        }.get(recipe.get("kind"))
        if schema_name is None:
            fail(f"{path.relative_to(ROOT)}: unknown recipe kind")
        Draft202012Validator(
            schemas[schema_name],
            format_checker=FormatChecker(),
        ).validate(recipe)
        print(f"example ok: {path.relative_to(ROOT)}")


def validate_openapi() -> None:
    path = ROOT / "contracts/openapi.yaml"
    try:
        document = load_openapi_document(path)
    except DuplicateKeyError as error:
        fail(f"{path.relative_to(ROOT)}: {error}")
    if document.get("openapi") != "3.1.0":
        fail("OpenAPI version must be 3.1.0")
    errors = list(OpenAPIV31SpecValidator(document).iter_errors())
    if errors:
        rendered = []
        for error in errors:
            location = "/".join(str(item) for item in error.absolute_path)
            rendered.append(f"{location or '<document>'}: {error.message}")
        fail("OpenAPI 3.1 validation failed:\n  " + "\n  ".join(rendered))
    validate_mutation_idempotency(document)
    validate_request_goldens(document)
    print(f"openapi 3.1 ok: {len(document['paths'])} paths")


def validate_mutation_idempotency(document: dict) -> None:
    """Every durable authenticated mutation declares its replay key."""
    # Exclude nondurable requests; replaying diagnostics would retain the private bundle in the database.
    bootstrap_or_inference = {
        ("/api/v1/pairing/challenge", "post"),
        ("/api/v1/pairing/claim", "post"),
        ("/api/v1/pairing/join-codes/redeem", "post"),
        # Each stateless PAKE attempt intentionally spends its own guessing budget.
        ("/api/v1/pairing/join-codes/exchange", "post"),
        ("/api/v1/presence/challenge", "post"),
        ("/v1/chat/completions", "post"),
        ("/api/v1/diagnostics/export", "post"),
        ("/v1/responses", "post"),
        ("/v1/audio/speech", "post"),
        # A web-tool answer is one generation, like a chat completion; it stores no resource to replay.
        ("/api/v1/web/answer", "post"),
        # Preparation starts or reports one host-wide job; repeating it changes nothing to replay.
        ("/api/v1/development/preparation", "post"),
    }
    missing: list[str] = []
    for path, path_item in document["paths"].items():
        for method in ("post", "put", "patch", "delete"):
            operation = path_item.get(method)
            if operation is None or (path, method) in bootstrap_or_inference:
                continue
            parameters = [*path_item.get("parameters", []), *operation.get("parameters", [])]
            if not any(
                parameter.get("$ref") == "#/components/parameters/IdempotencyKey"
                for parameter in parameters
            ):
                missing.append(f"{method.upper()} {path}")
    if missing:
        fail("durable mutations missing Idempotency-Key: " + ", ".join(missing))


def validate_request_goldens(document: dict) -> None:
    fixtures = {
        "createCluster": ROOT / "contracts/golden/requests/create-cluster.json",
        "registerBuildWorker": ROOT
        / "contracts/golden/requests/register-build-worker.json",
    }
    operations = {
        operation["operationId"]: operation
        for path_item in document["paths"].values()
        for method, operation in path_item.items()
        if method in {"get", "put", "post", "delete", "patch"}
    }
    for operation_id, fixture_path in fixtures.items():
        operation = operations[operation_id]
        schema = operation["requestBody"]["content"]["application/json"]["schema"]
        if "$ref" in schema:
            schema_name = schema["$ref"].removeprefix("#/components/schemas/")
            schema = document["components"]["schemas"][schema_name]
        fixture = load_json_strict(fixture_path)
        Draft202012Validator(schema, format_checker=FormatChecker()).validate(fixture)
        print(f"request golden ok: {fixture_path.relative_to(ROOT)}")


def validate_sql() -> None:
    sql = load_runtime_schema(ROOT)
    connection = sqlite3.connect(":memory:")
    try:
        connection.executescript(sql)
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
    finally:
        connection.close()

    required = {
        "devices",
        "pairing_invitations",
        "operations",
        "events",
        "models",
        "model_profiles",
        "audit_records",
        "projects",
    }
    missing = required - tables
    if missing:
        fail(f"SQL schema missing tables: {sorted(missing)}")
    print(f"sql schema ok: {len(tables)} tables")


def validate_release_canonicalization() -> None:
    """Release-signing bytes must match the shared Python, Rust and Swift fixture."""
    fixture_path = ROOT / "contracts/fixtures/release-manifest-canonicalization.json"
    if not fixture_path.is_file():
        fail(f"missing canonicalisation fixture: {fixture_path}")

    sys.path.insert(0, str(ROOT / "tools" / "release"))
    import spark_release

    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    if not fixture.get("cases"):
        fail("canonicalisation fixture contains no cases")

    for case in fixture["cases"]:
        actual = spark_release.canonical_bytes(case["manifest"])
        if actual.decode("utf-8") != case["canonical"]:
            fail(
                f"canonicalisation case {case['name']!r} disagrees with the fixture; "
                f"{case['why']}"
            )
        digest = hashlib.sha256(actual).hexdigest()
        if digest != case["canonical_sha256"]:
            fail(f"canonicalisation case {case['name']!r}: digest {digest}")
    print(f"canonicalisation ok: {len(fixture['cases'])} cases")


def validate_release_trust_root() -> None:
    """The shipped trust root must parse and stay inside its declared scope."""
    path = ROOT / "packaging/trust/release-keys.json"
    if not path.is_file():
        fail(f"missing release trust root: {path}")
    root = load_json_strict(path)
    try:
        validate_trust(root, canonical_bytes)
    except Exception as error:
        fail(f"invalid release trust: {error}")

    for key in root["keys"]:
        for field in ("key_id", "algorithm", "public_key", "channels", "purposes"):
            if field not in key:
                fail(f"trust root key is missing {field!r}")
        if key["algorithm"] != "ed25519":
            fail(f"trust root key {key['key_id']!r} is not ed25519")
        if len(key["public_key"]) != 64 or not all(
            character in "0123456789abcdef" for character in key["public_key"]
        ):
            fail(f"trust root key {key['key_id']!r} is not 32 hex-encoded bytes")
        # Schema 1 lacks an offline root and cannot authorize production channels.
        outside = sorted(set(key["channels"]) - {"dev", "lab"})
        if outside and root["schema"] == 1:
            fail(
                f"trust root key {key['key_id']!r} claims {', '.join(outside)}; "
                "the schema 1 direct-trust format is limited to dev and lab"
            )
        if "private" in json.dumps(key).lower():
            fail(f"trust root key {key['key_id']!r} looks like it carries private material")
    print(f"release trust root ok: {len(root['keys'])} key(s)")


def validate_embedded_trust_root() -> None:
    """The app trust root must match the shipped keys to avoid accepting revoked identities."""
    shipped = ROOT / "packaging/trust/release-keys.json"
    embedded = ROOT / "apple/SparkApp/Shared/Resources/release-keys.json"
    if not embedded.is_file():
        fail(f"the app has no embedded trust root at {embedded}")
    if shipped.read_bytes() != embedded.read_bytes():
        fail(
            f"{embedded.relative_to(ROOT)} differs from "
            f"{shipped.relative_to(ROOT)}; copy the shipped trust root over it"
        )
    print("embedded trust root ok: matches the shipped copy")


def validate_shared_fixture_copies() -> None:
    """Swift package copies must match the canonical fixtures used by runtime tests."""
    swift_fixtures = ROOT / "apple/Packages/SparkBootstrap/Tests/SparkBootstrapTests/Fixtures"
    shared = ROOT / "contracts/fixtures"
    checked = 0
    for name in sorted([p.name for p in shared.glob("*-canonicalization.json")] + ["release-delegation.json"]):
        copy = swift_fixtures / name
        if not copy.is_file():
            fail(f"the Swift tests have no copy of {name}")
        if (shared / name).read_bytes() != copy.read_bytes():
            fail(
                f"{copy.relative_to(ROOT)} differs from "
                f"contracts/fixtures/{name}; copy the shared fixture over it"
            )
        checked += 1

    shipped_copies = (
        (
            swift_fixtures / "release-keys.json",
            ROOT / "packaging/trust/release-keys.json",
        ),
        (
            swift_fixtures / "spark-runtime-0.1.0-dev.json",
            ROOT / "packaging/release-manifests/spark-runtime-0.1.0-dev.json",
        ),
    )
    for copy, shipped in shipped_copies:
        if not copy.is_file():
            fail(f"the Swift tests have no copy of {shipped.relative_to(ROOT)}")
        if not shipped.is_file():
            fail(f"missing shipped release input: {shipped.relative_to(ROOT)}")
        if shipped.read_bytes() != copy.read_bytes():
            fail(
                f"{copy.relative_to(ROOT)} differs from "
                f"{shipped.relative_to(ROOT)}; copy the shipped file over it"
            )
        checked += 1
    if checked == 0:
        fail("no shared canonicalisation fixtures found")
    print(f"shared fixtures ok: {checked} copy(ies) match")


def validate_invitation_canonicalization() -> None:
    """Pin invitation signing bytes, including the explicit null signature member."""
    path = ROOT / "contracts/fixtures/pairing-invitation-canonicalization.json"
    if not path.is_file():
        fail(f"missing invitation canonicalisation fixture: {path}")
    fixture = json.loads(path.read_text(encoding="utf-8"))
    cases = fixture.get("cases") or []
    if not cases:
        fail("the invitation canonicalisation fixture has no cases")
    for case in cases:
        for key in ("name", "why", "invitation", "canonical", "canonical_sha256"):
            if key not in case:
                fail(f"invitation case {case.get('name', '?')!r} is missing {key}")
        digest = hashlib.sha256(case["canonical"].encode("utf-8")).hexdigest()
        if digest != case["canonical_sha256"]:
            fail(f"invitation case {case['name']!r} digest does not match its canonical bytes")
        # Invitation signatures cover an explicit null signature member.
        if not case["canonical"].endswith(',"signature":null}'):
            fail(
                f"invitation case {case['name']!r} does not end with a null signature member; "
                "the runtime does not skip that member and the Apple side must not either"
            )
    print(f"invitation canonicalisation ok: {len(cases)} cases")


def main() -> None:
    require_supported_python()
    validate_source_lock()
    print("source lock ok")
    validate_json_schemas()
    validate_openapi()
    validate_sql()
    validate_release_canonicalization()
    validate_release_trust_root()
    validate_embedded_trust_root()
    validate_invitation_canonicalization()
    validate_shared_fixture_copies()
    print("all contract checks passed")


if __name__ == "__main__":
    main()
