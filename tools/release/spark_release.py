#!/usr/bin/env python3
"""Sign releases with purpose-scoped keys; see docs/build/TOOLING-INVARIANTS.md for commands and signing rules."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import stat
import sys

from pathlib import Path

if __package__:
    from . import release_delegation as delegation
else:
    import release_delegation as delegation

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
except ImportError:  # pragma: no cover - environment guidance
    print(
        "spark_release: this tool needs `cryptography` "
        "(python3 -m pip install cryptography)",
        file=sys.stderr,
    )
    raise SystemExit(2)

DEFAULT_KEY_DIR = Path.home() / ".spark-fabric" / "keys"
TRUST_SCHEMA = 1
ALGORITHM = "ed25519"

# Keep catalogue, package and manifest signing authority in separate key purposes.
MANIFEST_PURPOSE = "release-manifest"
PACKAGE_PURPOSE = "release-package"
CATALOGUE_PURPOSE = "model-catalogue"
PURPOSES = (MANIFEST_PURPOSE, PACKAGE_PURPOSE, CATALOGUE_PURPOSE, "release-delegation")

# Direct online-key trust lacks offline delegation and is limited to development and lab channels.
DIRECT_TRUST_CHANNELS = frozenset({"dev", "lab"})


def safe_artifact_path(directory: Path, name: str) -> Path:
    """Require a plain filename inside the artifact directory even when its manifest signature is valid."""
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        fail(f"artifact name {name!r} is not a plain file name")
    resolved = (directory / name).resolve()
    if resolved.parent != directory.resolve():
        fail(f"artifact name {name!r} resolves outside {directory}")
    return resolved


def fail(message: str) -> None:
    print(f"spark_release: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def unb64url(text: str) -> bytes:
    padding = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + padding)


def strip_nulls(value):
    """Omit null object members recursively to match Rust and Swift optional-field encoding."""
    if isinstance(value, dict):
        return {k: strip_nulls(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [strip_nulls(item) for item in value]
    return value


def canonical_bytes(manifest: dict) -> bytes:
    """Match the canonical signing algorithm pinned by contracts/fixtures/release-manifest-canonicalization.json."""
    unsigned = {key: value for key, value in manifest.items() if key != "signature"}
    return json.dumps(
        strip_nulls(unsigned),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")




def parse_rfc3339(text: str, what: str) -> dt.datetime:
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{what} is not an RFC 3339 timestamp: {text!r}")


def command_keygen(arguments: argparse.Namespace) -> int:
    # Validate policy before generating keys so rejected requests leave no secret material behind.
    if not arguments.key_id.strip():
        fail("--key-id must not be empty")
    unsupported = sorted(set(arguments.channels) - DIRECT_TRUST_CHANNELS)
    if unsupported and not arguments.delegation_only:
        fail(
            "the schema 1 trust root trusts online keys directly and is limited to "
            f"{', '.join(sorted(DIRECT_TRUST_CHANNELS))}; {', '.join(unsupported)} "
            "needs the offline-root delegation described in PLAN 45.3"
        )
    unknown = sorted(set(arguments.purposes) - set(PURPOSES))
    if unknown:
        fail(f"unknown key purposes: {', '.join(unknown)}")
    if not arguments.purposes:
        fail("a key must authorise at least one purpose")
    not_before = parse_rfc3339(arguments.not_before, "--not-before")
    not_after = parse_rfc3339(arguments.not_after, "--not-after")
    if not_after <= not_before:
        fail("--not-after must be later than --not-before")

    key_dir: Path = arguments.key_dir
    private_path = key_dir / f"{arguments.key_id}.ed25519"
    if private_path.exists() and not arguments.force:
        fail(f"{private_path} already exists; rotate to a new key id instead")

    key_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(key_dir, 0o700)

    private = Ed25519PrivateKey.generate()
    raw_private = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    raw_public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )

    # O_EXCL prevents concurrent or accidental key replacement unless --force explicitly permits it.
    flags = os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if arguments.force else os.O_EXCL)
    try:
        descriptor = os.open(private_path, flags, 0o600)
    except FileExistsError:
        fail(f"{private_path} already exists; rotate to a new key id instead")
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(raw_private)
    os.chmod(private_path, stat.S_IRUSR | stat.S_IWUSR)

    entry = {
        "key_id": arguments.key_id,
        "algorithm": ALGORITHM,
        "public_key": raw_public.hex(),
        "channels": arguments.channels,
        "purposes": arguments.purposes,
        "not_before": arguments.not_before,
        "not_after": arguments.not_after,
    }
    if arguments.comment:
        entry["comment"] = arguments.comment

    print(f"private key written to {private_path} (mode 0600, keep it out of git)",
          file=sys.stderr)
    print(json.dumps({"schema": TRUST_SCHEMA, "keys": [entry]}, indent=2))
    return 0




def command_manifest(arguments: argparse.Namespace) -> int:
    artifacts = []
    for path in arguments.artifact:
        if not path.is_file():
            fail(f"artifact does not exist: {path}")
        payload = path.read_bytes()
        artifacts.append(
            {
                "name": path.name,
                "architecture": "aarch64",
                "url": f"{arguments.base_url.rstrip('/')}/{path.name}",
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "signature_url": f"{arguments.base_url.rstrip('/')}/{path.name}.sig",
            }
        )

    manifest = {
        "version": arguments.version,
        "channel": arguments.channel,
        "released_at": arguments.released_at,
        "minimum_dgx_os": arguments.minimum_dgx_os,
        "api_version": arguments.api_version,
        "artifacts": artifacts,
    }
    if arguments.maximum_dgx_os:
        manifest["maximum_dgx_os"] = arguments.maximum_dgx_os

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote unsigned manifest {arguments.output}")
    return 0




def load_private_key(path: Path) -> Ed25519PrivateKey:
    if not path.is_file():
        fail(f"no release key at {path}; run `spark_release.py keygen` first")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        fail(f"{path} is group/world accessible (mode 0{mode:o}); refusing to sign")
    raw = path.read_bytes()
    if len(raw) != 32:
        fail(f"{path} is not a 32-byte Ed25519 seed")
    return Ed25519PrivateKey.from_private_bytes(raw)


def command_sign(arguments: argparse.Namespace) -> int:
    private = load_private_key(arguments.key)
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    manifest.pop("signature", None)

    # Sign every listed artifact so a verified manifest cannot imply verification of unsigned files.
    by_name = {artifact["name"]: artifact for artifact in manifest["artifacts"]}
    supplied = {path.name: path for path in arguments.artifact}

    unknown = sorted(set(supplied) - set(by_name))
    if unknown:
        fail(f"not listed in {arguments.manifest}: {', '.join(unknown)}")
    missing = sorted(set(by_name) - set(supplied))
    if missing:
        fail(
            "every manifest artifact must be signed; no file supplied for: "
            + ", ".join(missing)
        )

    for name in sorted(by_name):
        path = supplied[name]
        artifact = by_name[name]
        payload = path.read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != artifact["sha256"]:
            fail(
                f"{name} digest {digest} does not match the manifest "
                f"({artifact['sha256']}); rebuild the manifest"
            )
        signature_path = path.with_name(name + ".sig")
        signature_path.write_text(b64url(private.sign(payload)) + "\n", encoding="utf-8")
        print(f"signed artifact {signature_path}")

    manifest["signature"] = {
        "key_id": arguments.key_id,
        "algorithm": ALGORITHM,
        "value": b64url(private.sign(canonical_bytes(manifest))),
    }
    output = arguments.output or arguments.manifest
    output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"signed manifest {output}")
    return 0




def assert_key_usable(key: dict, channel: str, at: str | None, purpose=MANIFEST_PURPOSE) -> None:
    """Mirror of `TrustedKey::assert_usable` in the Rust installer."""
    if key.get("revoked_at"):
        fail(f"release key {key['key_id']!r} is revoked")
    if key["algorithm"] != ALGORITHM:
        fail(f"release key {key['key_id']!r} is not an {ALGORITHM} key")

    moment = parse_rfc3339(at, "--at") if at else dt.datetime.now(dt.timezone.utc)
    not_before = parse_rfc3339(key["not_before"], "not_before")
    not_after = parse_rfc3339(key["not_after"], "not_after")
    if not_after <= not_before:
        fail(f"release key {key['key_id']!r} has a validity window that ends before it starts")
    if moment < not_before or moment >= not_after:
        fail(
            f"release key {key['key_id']!r} is not valid at "
            f"{moment.isoformat()} (window {key['not_before']} .. {key['not_after']})"
        )

    if channel not in key["channels"]:
        fail(f"key {key['key_id']!r} is not authorised for channel {channel!r}")
    purposes = key.get("purposes", [])
    if purpose not in purposes:
        action = "release manifests" if purpose == MANIFEST_PURPOSE else "release packages"
        fail(
            f"key {key['key_id']!r} has purposes {purposes} and may not sign "
            f"{action} ({purpose!r} required)"
        )


def command_selftest(arguments: argparse.Namespace) -> int:
    """Check this implementation against the shared canonicalisation fixture."""
    fixture = json.loads(arguments.fixture.read_text(encoding="utf-8"))
    failures = 0
    for case in fixture["cases"]:
        actual = canonical_bytes(case["manifest"])
        expected = case["canonical"].encode("utf-8")
        if actual != expected:
            failures += 1
            print(f"FAIL {case['name']}", file=sys.stderr)
            print(f"  expected {expected!r}", file=sys.stderr)
            print(f"  actual   {actual!r}", file=sys.stderr)
            continue
        digest = hashlib.sha256(actual).hexdigest()
        if digest != case["canonical_sha256"]:
            failures += 1
            print(
                f"FAIL {case['name']}: sha256 {digest} != {case['canonical_sha256']}",
                file=sys.stderr,
            )
            continue
        print(f"canonical ok: {case['name']}")
    if failures:
        fail(f"{failures} canonicalisation case(s) disagree")
    print(f"all {len(fixture['cases'])} canonicalisation cases agree")
    return 0


def command_verify(arguments: argparse.Namespace) -> int:
    trust = json.loads(arguments.trust_root.read_text(encoding="utf-8"))
    try:
        delegation.validate_trust(trust, canonical_bytes)
    except Exception as error:
        fail(f"invalid release trust: {error}")
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))

    signature = manifest.get("signature")
    if not signature:
        fail("manifest has no signature")
    if signature.get("algorithm") != ALGORITHM:
        fail("unsupported manifest signature algorithm")
    key = next(
        (entry for entry in trust["keys"] if entry["key_id"] == signature["key_id"]),
        None,
    )
    if key is None:
        fail(f"no trusted key with id {signature['key_id']!r}")
    # Match the installer TrustedKey::assert_usable checks and their order.
    assert_key_usable(key, manifest["channel"], arguments.at)
    try:
        moment = delegation.timestamp(arguments.at) if arguments.at else dt.datetime.now(dt.timezone.utc)
        delegation.authorize_channel(trust, manifest["channel"], moment, canonical_bytes)
    except Exception as error:
        fail(f"invalid release delegation: {error}")

    material = key.get("public_key")
    if not isinstance(material, str) or len(material) != 64:
        fail("trust root key public_key must be 32 hex-encoded bytes")
    try:
        public_bytes = bytes.fromhex(material)
    except ValueError:
        # Convert malformed signatures into a controlled verification refusal.
        fail("trust root key public_key is not hexadecimal")
    public = Ed25519PublicKey.from_public_bytes(public_bytes)
    try:
        public.verify(unb64url(signature["value"]), canonical_bytes(manifest))
    except Exception:
        fail("manifest signature does not verify")
    print(f"manifest ok: {manifest['version']} ({manifest['channel']}) via {key['key_id']}")

    if arguments.manifest_only:
        print("manifest-only verification; artifacts were not checked")
        return 0

    assert_key_usable(key, manifest["channel"], arguments.at, PACKAGE_PURPOSE)
    artifact_dir = arguments.artifact_dir or arguments.manifest.parent
    for artifact in manifest["artifacts"]:
        # Reject artifact paths before reading or signing, even when the manifest has a valid signature.
        path = safe_artifact_path(artifact_dir, artifact["name"])
        if not path.is_file():
            fail(
                f"{artifact['name']} is listed in the manifest but absent from "
                f"{artifact_dir}; pass --manifest-only to check the manifest alone"
            )
        payload = path.read_bytes()
        if len(payload) != artifact["size"]:
            fail(f"{artifact['name']} is {len(payload)} bytes; manifest says {artifact['size']}")
        digest = hashlib.sha256(payload).hexdigest()
        if digest != artifact["sha256"]:
            fail(f"{artifact['name']} digest mismatch")

        signature_path = path.with_name(path.name + ".sig")
        if not signature_path.is_file():
            fail(
                f"{artifact['name']} has no detached signature at {signature_path}; "
                "every manifest artifact must be signed"
            )
        raw = signature_path.read_text(encoding="utf-8").strip()
        try:
            public.verify(unb64url(raw), payload)
        except Exception:
            fail(f"{artifact['name']} detached signature does not verify")
        print(f"artifact ok: {artifact['name']} (digest and detached signature)")
    return 0


def command_delegate(arguments):
    try:
        return delegation.delegate_command(arguments, canonical_bytes, load_private_key)
    except Exception as error:
        fail(f"delegation refused: {error}")


def today() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    keygen = subparsers.add_parser("keygen", help="create a release signing key")
    keygen.add_argument("--key-id", required=True)
    keygen.add_argument("--key-dir", type=Path, default=DEFAULT_KEY_DIR)
    keygen.add_argument("--channels", nargs="+", default=["dev"])
    keygen.add_argument("--purposes", nargs="+", default=[MANIFEST_PURPOSE, PACKAGE_PURPOSE])
    keygen.add_argument("--not-before", default="2026-01-01T00:00:00Z")
    keygen.add_argument("--not-after", default="2028-01-01T00:00:00Z")
    keygen.add_argument("--comment")
    keygen.add_argument("--force", action="store_true")
    keygen.add_argument("--delegation-only", action="store_true", help="emit an online/offline key request that requires offline delegation before production use")
    keygen.set_defaults(handler=command_keygen)

    delegate = subparsers.add_parser("delegate", help="offline-sign online release-key policy")
    delegate.add_argument("--root-record", type=Path, required=True)
    delegate.add_argument("--root-key", type=Path, required=True)
    delegate.add_argument("--online-keys", type=Path, required=True)
    delegate.add_argument("--version", type=int, required=True)
    delegate.add_argument("--minimum-version", type=int, default=1)
    delegate.add_argument("--not-before", required=True)
    delegate.add_argument("--not-after", required=True)
    delegate.set_defaults(handler=command_delegate)

    manifest = subparsers.add_parser("manifest", help="build an unsigned manifest")
    manifest.add_argument("--artifact", type=Path, nargs="+", required=True)
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--channel", default="dev")
    manifest.add_argument("--base-url", required=True)
    manifest.add_argument("--minimum-dgx-os", required=True)
    manifest.add_argument("--maximum-dgx-os")
    manifest.add_argument("--api-version", type=int, default=1)
    manifest.add_argument("--released-at", default=today())
    manifest.add_argument("--output", type=Path, required=True)
    manifest.set_defaults(handler=command_manifest)

    sign = subparsers.add_parser("sign", help="sign a manifest and its artifacts")
    sign.add_argument("--manifest", type=Path, required=True)
    sign.add_argument("--artifact", type=Path, nargs="+", required=True)
    sign.add_argument("--key", type=Path, required=True)
    sign.add_argument("--key-id", required=True)
    sign.add_argument("--output", type=Path)
    sign.set_defaults(handler=command_sign)

    verify = subparsers.add_parser("verify", help="verify a signed manifest")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--trust-root", type=Path, required=True)
    verify.add_argument("--artifact-dir", type=Path)
    verify.add_argument(
        "--at",
        help="verify as at this RFC 3339 instant instead of now (key-window tests)",
    )
    verify.add_argument(
        "--manifest-only",
        action="store_true",
        help="check the manifest signature alone; artifacts are not verified",
    )
    verify.set_defaults(handler=command_verify)

    selftest = subparsers.add_parser(
        "selftest", help="check canonicalisation against the shared fixture"
    )
    selftest.add_argument("--fixture", type=Path, required=True)
    selftest.set_defaults(handler=command_selftest)

    arguments = parser.parse_args(argv)
    return arguments.handler(arguments)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
