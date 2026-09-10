#!/usr/bin/env python3
"""Sign and review recipe provenance; commands and canonical rules are in docs/build/TOOLING-INVARIANTS.md."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, NoReturn

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
except ImportError:  # pragma: no cover
    print(
        "spark_catalogue.py needs the `cryptography` package; use the contracts venv "
        "(.build/contracts-venv312/bin/python3)",
        file=sys.stderr,
    )
    raise

ALGORITHM = "ed25519"
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCHEMA = REPO_ROOT / "contracts" / "schemas" / "model-recipe.schema.json"
PINNED_IMAGE = re.compile(r"[^@\s]+@sha256:([a-f0-9]{64})")

# Match Rust declaration order for known fields and preserve input order for unknown fields.
FIELD_ORDER: dict[str, list[str]] = {
    "": [
        "apiVersion", "kind", "metadata", "source", "engine", "capabilities",
        "memory", "profiles", "security", "signature",
    ],
    "metadata": ["id", "revision", "displayName", "publisher", "description",
                 "publisherURL", "recipeSource"],
    "metadata.recipeSource": ["name", "url", "revision", "retrievedAt"],
    "source": ["provider", "repository", "revision", "gated", "trustRemoteCode", "licenceURL"],
    "engine": ["recipe", "image", "servedName", "task", "tokenizerMode", "options"],
    "engine.options": ["preparation", "mambaCacheMode", "kvCacheDtype", "reasoningParser", "toolCallParser"],
    "capabilities": ["chat", "reasoning", "toolCalling", "parallelToolCalling",
                     "guidedGeneration", "vision", "embeddings", "audioInput"],
    "memory": ["minimumSystemReserveBytes", "expectedWeightBytes", "expectedEngineOverheadBytes",
               "kvCacheBytesPerToken", "stateBytesPerSequence", "measurementConfidence"],
    "profiles[]": ["id", "displayName", "maxModelLength", "maxSequences", "maxBatchedTokens",
                   "gpuMemoryUtilisation", "expectedPeakBytes", "idlePolicy"],
    "security": ["allowNetworkDuringInference", "allowedMediaRoots",
                 "allowCustomLogitsProcessors", "allowPlugins"],
    "signature": ["keyID", "algorithm", "value"],
}

# Fields serde always writes even when they were absent in the input.
ALWAYS_PRESENT = {"capabilities.parallelToolCalling": False}


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def b64url(raw: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def unb64url(text: str) -> bytes:
    import base64

    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def ordered(value: Any, path: str = "") -> Any:
    """Reorder an object tree into the runtime's declaration order."""
    if isinstance(value, list):
        return [ordered(item, f"{path}[]") for item in value]
    if not isinstance(value, dict):
        return value
    order = FIELD_ORDER.get(path, [])
    out: dict = {}
    for key in order:
        full = f"{path}.{key}" if path else key
        if key in value:
            out[key] = ordered(value[key], full)
        elif full in ALWAYS_PRESENT:
            out[key] = ALWAYS_PRESENT[full]
    for key, item in value.items():
        if key not in out:
            out[key] = ordered(item, f"{path}.{key}" if path else key)
    return out


def compact(value) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def recipe_canonical(recipe: dict) -> bytes:
    body = {k: v for k, v in recipe.items() if k != "signature"}
    return compact(ordered(body))


def catalogue_canonical(recipes: list[dict]) -> bytes:
    return compact([ordered(recipe) for recipe in recipes])


def load_private_key(path: Path) -> Ed25519PrivateKey:
    if not path.is_file():
        fail(f"no key at {path}")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        fail(f"{path} is group/world accessible (mode 0{mode:o}); refusing to sign")
    raw = path.read_bytes()
    if len(raw) != 32:
        fail(f"{path} is not a 32-byte Ed25519 seed")
    return Ed25519PrivateKey.from_private_bytes(raw)


def load_root(path: Path) -> Ed25519PublicKey:
    return Ed25519PublicKey.from_public_bytes(bytes.fromhex(path.read_text().strip()))


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"{path}: {error}")


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_against_schema(recipe: dict, schema_path: Path, required: bool = False) -> None:
    """Check a recipe against the contract schema; `required` turns a missing validator into a failure."""
    try:
        import jsonschema  # type: ignore
    except ImportError:
        if required:
            fail("jsonschema is not installed; use the contracts venv (.build/contracts-venv312/bin/python3)")
        print("note: jsonschema not installed; skipping schema validation", file=sys.stderr)
        return
    if not schema_path.is_file():
        fail(f"no recipe schema at {schema_path}")
    schema = read_json(schema_path)
    recipe_id = recipe.get("metadata", {}).get("id", "<recipe>")
    try:
        jsonschema.validate(recipe, schema, format_checker=jsonschema.FormatChecker())
    except jsonschema.ValidationError as error:
        location = "/".join(str(part) for part in error.absolute_path) or "<root>"
        fail(f"{recipe_id} fails the recipe schema at {location}: {error.message}")


def pinned_image_error(image: str) -> str | None:
    """Mirror ModelRecipe::validate: a real digest pin, never the all-zero scaffold placeholder."""
    match = PINNED_IMAGE.fullmatch(image)
    if match is None:
        return f"image is not digest-pinned: {image}"
    if set(match.group(1)) == {"0"}:
        return f"image carries the all-zero placeholder digest, not a resolved pin: {image}"
    return None


def memory_arithmetic_error(recipe: dict) -> str | None:
    """Mirror ModelRecipe::validate_memory_arithmetic: declared peaks must equal the recipe's own arithmetic (ADR-043)."""
    memory = recipe.get("memory", {})
    kv_per_token = memory.get("kvCacheBytesPerToken")
    state_per_sequence = memory.get("stateBytesPerSequence")
    if kv_per_token is None and state_per_sequence is None:
        return None
    if not kv_per_token or not state_per_sequence:
        return "kvCacheBytesPerToken and stateBytesPerSequence must both be present and positive"
    for profile in recipe.get("profiles", []):
        sequences = profile["maxSequences"]
        derived = (memory["expectedWeightBytes"] + kv_per_token * profile["maxModelLength"] * sequences
                   + state_per_sequence * sequences + memory["expectedEngineOverheadBytes"])
        if profile["expectedPeakBytes"] != derived:
            return (f"profile {profile['id']} declares expectedPeakBytes {profile['expectedPeakBytes']} "
                    f"but its arithmetic derives {derived}")
    return None


def signed_recipe(recipe: dict, key: Ed25519PrivateKey, key_id: str) -> dict:
    body: dict = dict(ordered({k: v for k, v in recipe.items() if k != "signature"}))
    body["signature"] = {
        "keyID": key_id,
        "algorithm": ALGORITHM,
        "value": b64url(key.sign(recipe_canonical(body))),
    }
    return body




def command_keygen(arguments: argparse.Namespace) -> int:
    key_dir: Path = arguments.key_dir
    private_path = key_dir / f"{arguments.key_id}.ed25519"
    if private_path.exists() and not arguments.force:
        fail(f"{private_path} already exists; rotate to a new key id instead")
    key_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(key_dir, 0o700)
    private = Ed25519PrivateKey.generate()
    raw = private.private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )
    flags = os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if arguments.force else os.O_EXCL)
    descriptor = os.open(private_path, flags, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(raw)
    public_hex = private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    ).hex()
    if arguments.root_out:
        arguments.root_out.write_text(public_hex + "\n", encoding="utf-8")
        print(f"trust root written to {arguments.root_out}")
    print(f"private key written to {private_path} (mode 0600, keep it out of git)",
          file=sys.stderr)
    print(json.dumps({"key_id": arguments.key_id, "public_key": public_hex}, indent=2))
    return 0


def command_sign(arguments: argparse.Namespace) -> int:
    key = load_private_key(arguments.key)
    for path in arguments.recipe:
        recipe = read_json(path)
        signed = signed_recipe(recipe, key, arguments.key_id)
        # Validate after signing because the schema requires a real signature value.
        if arguments.schema:
            validate_against_schema(signed, arguments.schema)
        write_json(path, signed)
        print(f"signed {path} as {arguments.key_id}")
    return 0


def command_assemble(arguments: argparse.Namespace) -> int:
    key = load_private_key(arguments.key)
    recipes = []
    for path in arguments.recipe:
        recipe = read_json(path)
        signed = signed_recipe(recipe, key, arguments.key_id)
        if arguments.schema:
            validate_against_schema(signed, arguments.schema)
        # Signing must not lend authority to a peak the arithmetic contradicts; verify would only catch it later.
        arithmetic_error = memory_arithmetic_error(signed)
        if arithmetic_error:
            fail(f"{signed['metadata']['id']} memory arithmetic: {arithmetic_error}")
        if arguments.rewrite:
            write_json(path, signed)
        recipes.append(signed)
    if not recipes:
        fail("a catalogue with no recipes is refused by the runtime; supply at least one")
    ids = [recipe["metadata"]["id"] for recipe in recipes]
    if len(set(ids)) != len(ids):
        fail(f"duplicate recipe ids: {ids}")
    snapshot = {
        "recipes": recipes,
        "signature": {
            "keyID": arguments.key_id,
            "algorithm": ALGORITHM,
            "value": b64url(key.sign(catalogue_canonical(recipes))),
        },
    }
    write_json(arguments.output, snapshot)
    print(f"assembled {arguments.output} with {len(recipes)} recipe(s): {', '.join(ids)}")
    return 0


def command_verify(arguments: argparse.Namespace) -> int:
    root = load_root(arguments.root)
    snapshot = read_json(arguments.catalogue)
    signature = snapshot.get("signature", {})
    if signature.get("keyID") != arguments.key_id:
        fail(f"catalogue signed by {signature.get('keyID')!r}, expected {arguments.key_id!r}")
    try:
        root.verify(unb64url(signature["value"]), catalogue_canonical(snapshot["recipes"]))
    except Exception as error:  # noqa: BLE001
        fail(f"catalogue signature does not verify: {error}")
    for recipe in snapshot["recipes"]:
        sig = recipe["signature"]
        if sig.get("keyID") != arguments.key_id:
            fail(f"{recipe['metadata']['id']} signed by {sig.get('keyID')!r}")
        try:
            root.verify(unb64url(sig["value"]), recipe_canonical(recipe))
        except Exception as error:  # noqa: BLE001
            fail(f"{recipe['metadata']['id']} signature does not verify: {error}")
        # A verified signature only proves authorship; the runtime still refuses recipes outside the contract.
        validate_against_schema(recipe, arguments.schema, required=True)
        image_error = pinned_image_error(recipe["engine"]["image"])
        if image_error:
            fail(f"{recipe['metadata']['id']} {image_error}")
        arithmetic_error = memory_arithmetic_error(recipe)
        if arithmetic_error:
            fail(f"{recipe['metadata']['id']} memory arithmetic: {arithmetic_error}")
    print(f"verified {arguments.catalogue}: {len(snapshot['recipes'])} recipe(s) under {arguments.key_id}")
    return 0


def command_release_check(arguments: argparse.Namespace) -> int:
    approval_path = REPO_ROOT / "packaging/catalogue/release-approvals.json"
    if not approval_path.is_file():
        fail("missing recipe release approvals")
    approvals = read_json(approval_path).get("recipes")
    if not isinstance(approvals, dict) or not approvals:
        fail("missing recipe release approvals")
    recipes = []
    for path in arguments.recipe:
        data = read_json(path)
        entries = data.get("recipes", []) if arguments.catalogue else [data]
        if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
            fail(f"invalid release recipes in {path}")
        recipes.extend(entries)
    if not recipes:
        fail("no recipes to check for release")
    seen = set()
    for recipe in recipes:
        identity = recipe.get("metadata", {}).get("id", "<unknown>")
        if identity in seen:
            fail(f"duplicate release recipe: {identity}")
        seen.add(identity)
        if identity not in approvals:
            fail(f"{identity} is not approved for release; complete recipes/README.md")
        observed = hashlib.sha256(recipe_canonical(recipe)).hexdigest()
        if approvals[identity] != observed:
            fail(f"{identity} changed since approval; review the exact recipe before release")
    print(f"release approval verified for {len(recipes)} recipe(s)")
    return 0



USER_AGENT = "spark-catalogue-scaffold/1"


def fetch(url: str, accept: str = "application/json") -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def fetch_json(url: str):
    return json.loads(fetch(url).decode("utf-8"))


def github_parts(url: str) -> tuple[str, str]:
    match = re.match(r"https?://github\.com/([^/]+)/([^/#?]+)", url)
    if not match:
        fail(f"not a GitHub repository URL: {url}")
    return match.group(1), match.group(2).removesuffix(".git")


HF_ID = re.compile(r"(?:huggingface\.co/|--model[= ]+|\"model\"\s*:\s*\")([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)")
IMAGE = re.compile(r"((?:vllm/vllm-openai|nvcr\.io/nvidia/vllm|nvcr\.io/nvidia/tritonserver)[A-Za-z0-9_.:@/-]*)")
FLAG = {
    "maxModelLength": re.compile(r"--max-model-len[= ]+(\d+)"),
    "gpuMemoryUtilisation": re.compile(r"--gpu-memory-utilization[= ]+([0-9.]+)"),
    "maxSequences": re.compile(r"--max-num-seqs[= ]+(\d+)"),
    "maxBatchedTokens": re.compile(r"--max-num-batched-tokens[= ]+(\d+)"),
    "kvCacheDtype": re.compile(r"--kv-cache-dtype[= ]+(\w+)"),
    "mambaCacheMode": re.compile(r"--mamba-cache-mode[= ]+(\w+)"),
    "reasoningParser": re.compile(r"--reasoning-parser[= ]+([\w-]+)"),
    "servedName": re.compile(r"--served-model-name[= ]+([A-Za-z0-9_.-]+)"),
}


def docker_hub_arm64_digest(image: str) -> str | None:
    """Resolve `vllm/vllm-openai:TAG` to its linux/arm64 image digest."""
    match = re.match(r"^(vllm/vllm-openai):([A-Za-z0-9_.-]+)$", image)
    if match is None:
        return None
    repository, tag = match.group(1), match.group(2)
    try:
        data = fetch_json(f"https://hub.docker.com/v2/repositories/{repository}/tags/{tag}")
    except (urllib.error.URLError, json.JSONDecodeError):
        return None
    for entry in data.get("images", []):
        if entry.get("architecture") == "arm64" and entry.get("os") == "linux":
            return f"{repository}@{entry['digest']}"
    return None


def huggingface_revision(repository: str) -> tuple[str | None, bool, int | None]:
    try:
        info = fetch_json(f"https://huggingface.co/api/models/{repository}")
        tree = fetch_json(f"https://huggingface.co/api/models/{repository}/tree/main")
    except (urllib.error.URLError, json.JSONDecodeError):
        return None, False, None
    weights = sum(
        entry.get("size", 0) for entry in tree
        if isinstance(entry, dict) and entry.get("path", "").endswith(".safetensors")
    )
    return info.get("sha"), bool(info.get("gated")), weights or None


def command_scaffold(arguments: argparse.Namespace) -> int:
    owner, repo = github_parts(arguments.github)
    meta = fetch_json(f"https://api.github.com/repos/{owner}/{repo}")
    branch = meta.get("default_branch", "main")
    head = fetch_json(f"https://api.github.com/repos/{owner}/{repo}/commits/{branch}")
    revision = head.get("sha")
    text = ""
    for name in ("README.md", "readme.md", "README", "run.sh", "serve.sh", "launch.sh", "start.sh"):
        try:
            text += fetch(
                f"https://raw.githubusercontent.com/{owner}/{repo}/{revision}/{name}",
                accept="text/plain",
            ).decode("utf-8", "replace") + "\n"
        except urllib.error.HTTPError:
            continue
    if not text.strip():
        fail("the repository has no README or launch script to read")

    models = [m for m in dict.fromkeys(HF_ID.findall(text)) if not m.lower().startswith("huggingface")]
    images = list(dict.fromkeys(IMAGE.findall(text)))
    flags = {name: pattern.search(text) for name, pattern in FLAG.items()}
    model = arguments.model or (models[0] if models else "TODO/owner-model")
    image_ref = arguments.image or (images[0] if images else "vllm/vllm-openai:TODO")
    image = image_ref if PINNED_IMAGE.fullmatch(image_ref) else docker_hub_arm64_digest(image_ref)
    # A placeholder digest would pass review by accident, so an unresolved image stops the scaffold.
    if image is None or pinned_image_error(image):
        fail(f"could not resolve {image_ref!r} to a linux/arm64 digest; pass --image REPOSITORY@sha256:DIGEST")
    hf_revision, gated, weights = huggingface_revision(model)

    def flag(name: str, default):
        match = flags.get(name)
        if not match:
            return default
        value = match.group(1)
        try:
            return type(default)(value) if not isinstance(default, str) else value
        except ValueError:
            return default

    display = model.split("/")[-1].replace("-", " ")
    recipe = {
        "apiVersion": "spark.runtime/v1",
        "kind": "ModelRecipe",
        "metadata": {
            "id": model.lower(),
            "revision": f"{dt.date.today().isoformat()}.draft",
            "displayName": display,
            "publisher": model.split("/")[0],
            "description": (meta.get("description") or "TODO: describe the model in one sentence.").strip(),
            "publisherURL": f"https://huggingface.co/{model.split('/')[0]}",
            "recipeSource": {
                "name": owner,
                "url": f"https://github.com/{owner}/{repo}",
                "revision": revision,
                "retrievedAt": dt.date.today().isoformat(),
            },
        },
        "source": {
            "provider": "huggingface",
            "repository": model,
            "revision": hf_revision or "TODO-immutable-commit-sha",
            "gated": gated,
            "trustRemoteCode": False,
            "licenceURL": f"https://huggingface.co/{model}/blob/{hf_revision or 'main'}/LICENSE",
        },
        "engine": {
            "recipe": "vllm-dgx-spark-2026-09",
            "image": image,
            "servedName": flag("servedName", model.split("/")[-1].lower()),
            "task": "generate",
            "tokenizerMode": "auto",
        },
        "capabilities": {
            "chat": True, "reasoning": False, "toolCalling": False, "parallelToolCalling": False,
            "guidedGeneration": False, "vision": False, "embeddings": False, "audioInput": False,
        },
        "memory": {
            "minimumSystemReserveBytes": 23622320128,
            "expectedWeightBytes": weights or 1,
            "expectedEngineOverheadBytes": 8589934592,
            "measurementConfidence": "estimated",
        },
        "profiles": [
            {
                "id": "default",
                "displayName": "Default",
                "maxModelLength": flag("maxModelLength", 65536),
                "maxSequences": flag("maxSequences", 4),
                "maxBatchedTokens": flag("maxBatchedTokens", 8192),
                "gpuMemoryUtilisation": flag("gpuMemoryUtilisation", 0.7),
                "expectedPeakBytes": 96000000000,
                "idlePolicy": "unload_after_30m",
            }
        ],
        "security": {
            "allowNetworkDuringInference": False,
            "allowedMediaRoots": [],
            "allowCustomLogitsProcessors": False,
            "allowPlugins": [],
        },
        "signature": {"keyID": "unsigned", "algorithm": ALGORITHM, "value": ""},
    }
    options: dict[str, str] = {}
    mamba = flags.get("mambaCacheMode")
    if mamba is not None:
        options["mambaCacheMode"] = mamba.group(1)
    kv_dtype = flags.get("kvCacheDtype")
    if kv_dtype is not None:
        options["kvCacheDtype"] = kv_dtype.group(1)
    if options:
        recipe["engine"]["options"] = options

    write_json(arguments.output, ordered(recipe))
    todo = [line for line in json.dumps(recipe).split(",") if "TODO" in line]
    print(f"draft written to {arguments.output} from github.com/{owner}/{repo}@{(revision or '')[:12]}")
    print(f"  model: {model}  image: {image_ref}  models seen: {', '.join(models[:5]) or 'none'}")
    if todo:
        print("  review before signing: " + "; ".join(todo))
    print("  memory figures and profiles are guesses until measured on a Spark; "
          "check the licence, then sign with `spark_catalogue.py sign`.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    keygen = commands.add_parser("keygen")
    keygen.add_argument("--key-id", required=True)
    keygen.add_argument("--key-dir", type=Path, required=True)
    keygen.add_argument("--root-out", type=Path)
    keygen.add_argument("--force", action="store_true")
    keygen.set_defaults(handler=command_keygen)

    sign = commands.add_parser("sign")
    sign.add_argument("--key", type=Path, required=True)
    sign.add_argument("--key-id", required=True)
    sign.add_argument("--schema", type=Path)
    sign.add_argument("recipe", type=Path, nargs="+")
    sign.set_defaults(handler=command_sign)

    assemble = commands.add_parser("assemble")
    assemble.add_argument("--key", type=Path, required=True)
    assemble.add_argument("--key-id", required=True)
    assemble.add_argument("--schema", type=Path)
    assemble.add_argument("--output", type=Path, required=True)
    assemble.add_argument("--rewrite", action="store_true", help="also write the signed recipe back to each input file")
    assemble.add_argument("recipe", type=Path, nargs="+")
    assemble.set_defaults(handler=command_assemble)

    verify = commands.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--key-id", required=True)
    verify.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA,
                        help="recipe schema every entry must satisfy (default: the repository contract)")
    verify.add_argument("catalogue", type=Path)
    verify.set_defaults(handler=command_verify)

    release_check = commands.add_parser("release-check")
    release_check.add_argument("--catalogue", action="store_true")
    release_check.add_argument("recipe", type=Path, nargs="+")
    release_check.set_defaults(handler=command_release_check)

    scaffold = commands.add_parser("scaffold")
    scaffold.add_argument("--github", required=True)
    scaffold.add_argument("--model", help="Hugging Face id, when the repository serves several")
    scaffold.add_argument("--image", help="engine image to pin: a TAG reference to resolve on Docker Hub, or REPOSITORY@sha256:DIGEST")
    scaffold.add_argument("--output", type=Path, required=True)
    scaffold.set_defaults(handler=command_scaffold)

    arguments = parser.parse_args(argv)
    return arguments.handler(arguments)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
