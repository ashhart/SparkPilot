"""Verify offline release delegation; trust anchors are supplied by a previously authenticated installation."""

import base64
import datetime as dt
import json
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

DOMAIN = b"SPARK-RELEASE-DELEGATION-V2\n"
PURPOSES = {"release-manifest", "release-package", "model-catalogue", "release-delegation"}


def timestamp(value):
    import re
    if not isinstance(value, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})", value
    ):
        raise ValueError("invalid RFC 3339 timestamp")
    return dt.datetime.fromisoformat(value.upper().replace("Z", "+00:00"))


def require_fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise ValueError("unknown or missing trust fields")


def validate_key(key):
    require_fields(key, {"key_id", "algorithm", "public_key", "channels", "purposes", "not_before", "not_after"}, {"revoked_at", "comment"})
    if not isinstance(key["key_id"], str) or not key["key_id"].strip() or key["algorithm"] != "ed25519":
        raise ValueError("invalid key ID or algorithm")
    if not isinstance(key["public_key"], str) or len(key["public_key"]) != 64:
        raise ValueError("invalid public key")
    public = Ed25519PublicKey.from_public_bytes(bytes.fromhex(key["public_key"]))
    for field in ("channels", "purposes"):
        if not isinstance(key[field], list) or not key[field] or any(not isinstance(v, str) for v in key[field]):
            raise ValueError("invalid key scope")
    if set(key["purposes"]) - PURPOSES:
        raise ValueError("unknown key purpose")
    before, after = timestamp(key["not_before"]), timestamp(key["not_after"])
    if before >= after:
        raise ValueError("invalid key window")
    if key.get("revoked_at") is not None:
        timestamp(key["revoked_at"])
    return public, before, after


def signed_payload(trust, canonical):
    delegation = trust["delegation"]
    return DOMAIN + canonical(dict(schema=2, keys=trust["keys"], **{
        k: delegation[k] for k in ("version", "not_before", "not_after")
    }))


def validate_trust(trust, canonical):
    schema = trust.get("schema")
    if schema == 1:
        require_fields(trust, {"schema", "keys"})
        roots = []
    elif schema == 2:
        require_fields(trust, {"schema", "keys", "root_keys", "minimum_delegation_version", "delegation"})
        roots = trust["root_keys"]
        if not isinstance(roots, list) or not roots:
            raise ValueError("missing offline roots")
    else:
        raise ValueError("unsupported trust schema")
    keys = trust["keys"]
    if not isinstance(keys, list) or not keys:
        raise ValueError("empty trust keys")
    seen = set()
    for key in keys + roots:
        validate_key(key)
        if key["key_id"] in seen:
            raise ValueError("duplicate key ID")
        seen.add(key["key_id"])
    if schema == 1:
        return
    delegation = trust["delegation"]
    require_fields(delegation, {"version", "not_before", "not_after", "signature"})
    minimum, version = trust["minimum_delegation_version"], delegation["version"]
    if type(minimum) is not int or type(version) is not int or not 0 < minimum <= version <= 2**63-1:
        raise ValueError("invalid or stale delegation version")
    signature = delegation["signature"]
    require_fields(signature, {"key_id", "algorithm", "value"})
    root = next((k for k in roots if k["key_id"] == signature["key_id"]), None)
    if root is None or signature["algorithm"] != "ed25519":
        raise ValueError("unknown offline key or algorithm")
    for entry in roots:
        if entry["purposes"] != ["release-delegation"]:
            raise ValueError("offline root purpose must be release-delegation only")
    public, root_before, root_after = validate_key(root)
    before, after = timestamp(delegation["not_before"]), timestamp(delegation["not_after"])
    if not root_before <= before < after <= root_after:
        raise ValueError("delegation exceeds root window")
    for key in keys:
        _, key_before, key_after = validate_key(key)
        if not before <= key_before < key_after <= after or set(key["channels"]) - set(root["channels"]):
            raise ValueError("online key exceeds delegated scope or window")
        purposes = set(key["purposes"])
        if "release-delegation" in purposes or ("model-catalogue" in purposes and purposes - {"model-catalogue"}):
            raise ValueError("offline, catalogue and release authorities must be separate")
        if any(key["public_key"].lower() == r["public_key"].lower() for r in roots):
            raise ValueError("offline key reused online")
    raw = signature["value"]
    if not isinstance(raw, str) or len(raw) != 86:
        raise ValueError("malformed delegation signature")
    decoded = base64.b64decode(raw + "==", altchars=b"-_", validate=True)
    public.verify(decoded, signed_payload(trust, canonical))


def authorize_channel(trust, channel, moment, canonical):
    validate_trust(trust, canonical)
    if trust["schema"] == 1:
        if channel not in {"dev", "lab"}:
            raise ValueError("channel requires offline-root delegation")
        return
    delegation = trust["delegation"]
    root = next(k for k in trust["root_keys"] if k["key_id"] == delegation["signature"]["key_id"])
    if root.get("revoked_at") is not None:
        raise ValueError("offline root is revoked")
    for value in (root, delegation):
        if not timestamp(value["not_before"]) <= moment < timestamp(value["not_after"]):
            raise ValueError("offline root or delegation expired or not yet valid")
    if channel not in root["channels"]:
        raise ValueError("offline root does not authorize channel")


def delegate_command(arguments, canonical, private_loader):
    source = json.loads(arguments.root_record.read_text())
    if source.get("schema") != 1 or len(source.get("keys", [])) != 1:
        raise ValueError("root record must contain exactly one offline key")
    root = source["keys"][0]
    private = private_loader(arguments.root_key)
    request = json.loads(arguments.online_keys.read_text())
    trust = dict(schema=2, keys=request["keys"], root_keys=[root],
                 minimum_delegation_version=arguments.minimum_version,
                 delegation=dict(version=arguments.version, not_before=arguments.not_before, not_after=arguments.not_after))
    trust["delegation"]["signature"] = dict(key_id=root["key_id"], algorithm="ed25519", value=
        base64.urlsafe_b64encode(private.sign(signed_payload(trust, canonical))).decode().rstrip("="))
    validate_trust(trust, canonical)
    print(json.dumps(trust, indent=2))
    return 0
