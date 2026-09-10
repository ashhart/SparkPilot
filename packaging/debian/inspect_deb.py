#!/usr/bin/env python3
"""Independently read Debian archives and verify required paths, modes, units and forbidden state."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import lzma
import re
import sys
import tarfile
from pathlib import Path
from typing import NoReturn

AR_MAGIC = b"!<arch>\n"
AR_HEADER_SIZE = 60

# Require the complete runtime package layout.
REQUIRED_FILES = {
    "./usr/lib/spark-runtime/sparkd": 0o755,
    "./usr/lib/spark-runtime/spark-privd": 0o755,
    "./usr/lib/spark-runtime/spark-updater": 0o755,
    "./usr/lib/spark-runtime/spark-installer": 0o755,
    "./usr/lib/systemd/system/sparkd.service": 0o644,
    "./usr/lib/systemd/system/spark-privd.service": 0o644,
    "./usr/lib/systemd/system/spark-updater.service": 0o644,
    "./usr/lib/systemd/system/spark-runtime-update@.service": 0o644,
    "./usr/share/spark-runtime/package-version": 0o644,
    "./usr/share/spark-runtime/catalog/bootstrap.json": 0o644,
    "./usr/share/spark-runtime/trust/catalogue-root.pub": 0o644,
    "./usr/share/spark-runtime/trust/service-root.pub": 0o644,
    "./usr/share/spark-runtime/trust/release-keys.json": 0o644,
    "./usr/share/spark-runtime/services/open-webui.service.json": 0o644,
    "./etc/spark-runtime/config.toml.example": 0o644,
}

REQUIRED_PREFIXES = ["./usr/share/spark-runtime/schema/"]

REQUIRED_CONTROL = {
    "./control": 0o644,
    "./md5sums": 0o644,
    "./preinst": 0o755,
    "./postinst": 0o755,
    "./prerm": 0o755,
    "./postrm": 0o755,
}

# PLAN §11.5 forbids model weights, credentials, owner keys and mutable generated state in the package.
FORBIDDEN_SUFFIXES = (
    ".safetensors",
    ".gguf",
    ".bin",
    ".pt",
    ".ckpt",
    ".pem",
    ".key",
    ".p12",
    ".pfx",
)
FORBIDDEN_NAMES = (
    "identity.key",
    "node.key",
    "runtime.db",
    "config.toml",
    ".env",
    "credentials.json",
)
FORBIDDEN_SUBSTRINGS = (
    "PRIVATE KEY",
    "hf_",
    "BEGIN OPENSSH",
)


def fail(message: str) -> "NoReturn":
    print(f"inspect_deb: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_ar(path: Path) -> dict[str, bytes]:
    """Parse the `ar` container into {member name: payload}."""
    data = path.read_bytes()
    if not data.startswith(AR_MAGIC):
        fail(f"{path} is not an ar archive")

    members: dict[str, bytes] = {}
    offset = len(AR_MAGIC)
    while offset < len(data):
        header = data[offset : offset + AR_HEADER_SIZE]
        if len(header) < AR_HEADER_SIZE:
            fail("truncated ar header")
        if header[58:60] != b"`\n":
            fail("bad ar header magic")
        name = header[0:16].decode("ascii").strip().rstrip("/")
        raw_size = header[48:58].decode("ascii").strip()
        if not raw_size.isdigit():
            fail(f"bad ar member size for {name!r}: {raw_size!r}")
        size = int(raw_size)
        start = offset + AR_HEADER_SIZE
        members[name] = data[start : start + size]
        offset = start + size + (size % 2)
    return members


def read_tar(payload: bytes) -> tarfile.TarFile:
    return tarfile.open(fileobj=io.BytesIO(lzma.decompress(payload)), mode="r:")


def contents(archive: tarfile.TarFile, member: tarfile.TarInfo | str) -> bytes:
    """Read a regular member. Callers only pass members they already found."""
    handle = archive.extractfile(member)
    if handle is None:
        fail(f"{member} is not a readable regular file")
    return handle.read()


def parse_control(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    key = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and key:
            fields[key] += "\n" + line.strip()
        elif ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            fields[key] = value.strip()
    return fields


def parse_unit(text: str) -> dict[str, list[str]]:
    """Flatten a unit file, joining backslash continuations."""
    joined: list[str] = []
    buffer = ""
    for raw in text.splitlines():
        line = raw.strip()
        if buffer:
            line = buffer + " " + line
            buffer = ""
        if line.endswith("\\"):
            buffer = line[:-1].strip()
            continue
        joined.append(line)

    directives: dict[str, list[str]] = {}
    for line in joined:
        if not line or line.startswith("#") or line.startswith("["):
            if line.startswith("["):
                directives.setdefault("__sections__", []).append(line)
            continue
        key, _, value = line.partition("=")
        directives.setdefault(key.strip(), []).append(value.strip())
    return directives


def check_units(data: tarfile.TarFile) -> list[str]:
    """Check packaged service arguments and credentials because binary tests cannot detect invalid unit configuration."""
    problems: list[str] = []
    members = {member.name: member for member in data.getmembers()}
    units: dict[str, dict[str, list[str]]] = {}

    for name in ("sparkd", "spark-privd", "spark-updater", "spark-runtime-update@"):
        path = f"./usr/lib/systemd/system/{name}.service"
        member = members.get(path)
        if member is None:
            problems.append(f"missing unit {path}")
            continue
        units[name] = parse_unit(contents(data, member).decode("utf-8"))

    sparkd = units.get("sparkd", {})
    exec_start = " ".join(sparkd.get("ExecStart", []))
    if "--data-dir /var/lib/spark-runtime" not in exec_start:
        problems.append(
            "sparkd.service must pass --data-dir /var/lib/spark-runtime; without it "
            "sparkd resolves a path relative to the working directory, which "
            "ProtectSystem=strict makes read-only"
        )
    if "--config /etc/spark-runtime/config.toml" not in exec_start:
        problems.append("sparkd.service must pass --config /etc/spark-runtime/config.toml")
    expected_credentials = {f"{name}:/etc/spark-runtime/identity/{name}"
                            for name in ("identity.key", "identity.json", "node.key", "node.crt")}
    for consumer in ("sparkd", "spark-updater"):
        unit = units.get(consumer, {})
        if set(unit.get("LoadCredential", [])) != expected_credentials:
            problems.append(f"{consumer}.service must load all four root-owned identity credentials")
        if "--identity-credentials %d" not in " ".join(unit.get("ExecStart", [])):
            problems.append(f"{consumer}.service must consume its immutable systemd credential directory")
    if sparkd.get("Type") != ["notify"]:
        problems.append(f"sparkd.service Type is {sparkd.get('Type')}, expected notify")

    privd = units.get("spark-privd", {})
    privd_exec = " ".join(privd.get("ExecStart", []))
    if "--allowed-user sparkd" not in privd_exec:
        problems.append(
            "spark-privd.service must pass --allowed-user sparkd; otherwise the helper "
            "defaults to allowing its own euid, which is root, and refuses sparkd"
        )
    if "--socket-group sparkd" not in privd_exec:
        problems.append(
            "spark-privd.service must pass --socket-group sparkd; otherwise the socket "
            "is root:root and sparkd cannot open it"
        )
    if privd.get("Group") != ["sparkd"]:
        problems.append(f"spark-privd.service Group is {privd.get('Group')}, expected sparkd")
    if privd.get("Type") != ["notify"]:
        problems.append(f"spark-privd.service Type is {privd.get('Type')}, expected notify")
    if privd.get("StateDirectory") != ["spark-privd"]:
        problems.append(
            "spark-privd.service must own StateDirectory=spark-privd for its root-only "
            "network rollback journal"
        )
    if privd.get("StateDirectoryMode") != ["0700"]:
        problems.append(
            f"spark-privd.service StateDirectoryMode is {privd.get('StateDirectoryMode')}, "
            "expected 0700"
        )
    privd_write_paths = " ".join(privd.get("ReadWritePaths", []))
    if "/var/lib/spark-privd" not in privd_write_paths.split():
        problems.append(
            "spark-privd.service ProtectSystem policy does not allow its rollback state path"
        )

    # One unit must own the runtime directory so service start order cannot change socket ownership.
    owners = [
        name
        for name, unit in units.items()
        if any(value == "spark-runtime" for value in unit.get("RuntimeDirectory", []))
    ]
    if owners != ["spark-privd"]:
        problems.append(
            f"RuntimeDirectory=spark-runtime is declared by {owners or 'nobody'}; "
            "exactly spark-privd must own it"
        )

    updater = units.get("spark-updater", {})
    if updater.get("Type") != ["oneshot"]:
        problems.append(f"spark-updater.service Type is {updater.get('Type')}, expected oneshot")
    if "[Install]" in updater.get("__sections__", []):
        problems.append(
            "spark-updater.service has an [Install] section; the health gate is run on "
            "demand, not enabled at boot"
        )

    worker = units.get("spark-runtime-update@", {})
    worker_exec = " ".join(worker.get("ExecStart", []))
    if worker.get("Type") != ["oneshot"]:
        problems.append(
            f"spark-runtime-update@.service Type is {worker.get('Type')}, expected oneshot"
        )
    if worker_exec != "/usr/lib/spark-runtime/spark-updater worker --release-id %i":
        problems.append(
            "spark-runtime-update@.service must execute only the fixed updater worker argv"
        )
    if "[Install]" in worker.get("__sections__", []):
        problems.append("spark-runtime-update@.service must not be enabled at boot")
    if worker.get("User") != ["root"]:
        problems.append("spark-runtime-update@.service must run as root")

    return problems


def check_manifest(data: tarfile.TarFile, control: tarfile.TarFile, schema_version: str | None):
    data_members = {member.name: member for member in data.getmembers()}
    control_members = {member.name: member for member in control.getmembers()}

    problems: list[str] = []

    for name, mode in REQUIRED_FILES.items():
        member = data_members.get(name)
        if member is None:
            problems.append(f"missing required file {name}")
            continue
        if not member.isreg():
            problems.append(f"{name} is not a regular file")
        elif member.mode != mode:
            problems.append(f"{name} has mode 0o{member.mode:o}, expected 0o{mode:o}")
        if member.uid != 0 or member.gid != 0:
            problems.append(f"{name} is not owned by root:root in the archive")

    version_path = "./usr/share/spark-runtime/package-version"
    version_member = data_members.get(version_path)
    if version_member is not None and version_member.isreg():
        fields = parse_control(contents(control, "./control").decode("utf-8"))
        expected = (fields.get("Version", "") + "\n").encode("ascii")
        if contents(data, version_member) != expected:
            problems.append("runtime identity version differs from Debian control Version")

    for prefix in REQUIRED_PREFIXES:
        if not any(name.startswith(prefix) and data_members[name].isreg() for name in data_members):
            problems.append(f"no files under {prefix}")

    for name, mode in REQUIRED_CONTROL.items():
        member = control_members.get(name)
        if member is None:
            problems.append(f"missing control member {name}")
        elif member.mode != mode:
            problems.append(f"control {name} has mode 0o{member.mode:o}, expected 0o{mode:o}")

    for name, member in data_members.items():
        if not member.isreg():
            continue
        base = Path(name).name
        if base in FORBIDDEN_NAMES:
            problems.append(f"package ships generated or secret state: {name}")
        if name.endswith(FORBIDDEN_SUFFIXES):
            problems.append(f"package ships a forbidden file type: {name}")
        # Model weights would dwarf anything the package legitimately holds.
        if member.size > 64 * 1024 * 1024:
            problems.append(f"{name} is {member.size} bytes; model weights must not be packaged")

    for name in ("./usr/share/spark-runtime/trust/release-keys.json",):
        member = data_members.get(name)
        if member is not None:
            body = contents(data, member).decode("utf-8", "replace")
            for needle in FORBIDDEN_SUBSTRINGS:
                if needle in body:
                    problems.append(f"{name} appears to contain secret material ({needle})")

    catalogue_name = "./usr/share/spark-runtime/catalog/bootstrap.json"
    catalogue_member = data_members.get(catalogue_name)
    root_name = "./usr/share/spark-runtime/trust/catalogue-root.pub"
    root_member = data_members.get(root_name)

    service_root_name = "./usr/share/spark-runtime/trust/service-root.pub"
    service_recipe_name = "./usr/share/spark-runtime/services/open-webui.service.json"
    service_root_member = data_members.get(service_root_name)
    service_recipe_member = data_members.get(service_recipe_name)
    if service_root_member is not None:
        service_root = contents(data, service_root_member).decode("ascii", "replace").strip()
        if re.fullmatch(r"[a-f0-9]{64}", service_root) is None:
            problems.append(f"{service_root_name} is not one Ed25519 public key")
    if service_recipe_member is not None:
        try:
            service_recipe = json.loads(contents(data, service_recipe_member))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            problems.append(f"{service_recipe_name} is not valid JSON: {error}")
        else:
            image = service_recipe.get("container", {}).get("image", "")
            signature = service_recipe.get("signature", {})
            if service_recipe.get("kind") != "ServiceRecipe":
                problems.append(f"{service_recipe_name} has the wrong kind")
            if re.fullmatch(
                r"ghcr\.io/open-webui/open-webui@sha256:[a-f0-9]{64}", image
            ) is None:
                problems.append(f"{service_recipe_name} image is not digest pinned")
            if signature.get("keyID") != "service-2026-a" or not signature.get("value"):
                problems.append(f"{service_recipe_name} has no accepted signature")
    if catalogue_member is not None:
        try:
            catalogue = json.loads(contents(data, catalogue_member))
            recipes = catalogue.get("recipes")
            signature = catalogue.get("signature")
            if not isinstance(recipes, list) or not recipes:
                problems.append("bootstrap catalogue must contain at least one recipe")
            if not isinstance(signature, dict) or not signature.get("value"):
                problems.append("bootstrap catalogue must carry an envelope signature")
            for recipe in recipes if isinstance(recipes, list) else []:
                image = recipe.get("engine", {}).get("image", "")
                revision = recipe.get("source", {}).get("revision", "")
                recipe_signature = recipe.get("signature", {}).get("value", "")
                if not re.fullmatch(r"[^@]+@sha256:[0-9a-f]{64}", image):
                    problems.append("bootstrap recipe engine image is not digest-pinned")
                if image.endswith("0" * 64):
                    problems.append("bootstrap recipe still carries a zero image digest")
                if not re.fullmatch(r"[0-9a-f]{40}", revision):
                    problems.append("bootstrap recipe source revision is not an immutable commit")
                if not recipe_signature:
                    problems.append("bootstrap recipe is unsigned")
        except (UnicodeDecodeError, json.JSONDecodeError, AttributeError) as error:
            problems.append(f"bootstrap catalogue is not valid JSON: {error}")
    if root_member is not None:
        root = contents(data, root_member).decode("ascii", "replace").strip()
        if not re.fullmatch(r"[0-9a-f]{64}", root):
            problems.append("catalogue root must be one raw Ed25519 public key in hex")

    config_member = data_members.get("./etc/spark-runtime/config.toml.example")
    if config_member is not None:
        config = contents(data, config_member).decode("utf-8", "replace")
        if 'catalogue_path = "/var/lib/spark-runtime/catalogue/catalogue.json"' not in config:
            problems.append("packaged config does not select the mutable verified catalogue")
        if 'catalogue_root_key_path = "/usr/share/spark-runtime/trust/catalogue-root.pub"' not in config:
            problems.append("packaged config does not select the catalogue trust root")

    # Require the baked schema version because an unsubstituted placeholder disables downgrade preflight.
    preinst = control_members.get("./preinst")
    if preinst is not None:
        body = contents(control, preinst).decode("utf-8", "replace")
        if "@SCHEMA_VERSION@" in body:
            problems.append("preinst still contains the @SCHEMA_VERSION@ placeholder")
        if schema_version and f'NEW_SCHEMA_VERSION="{schema_version}"' not in body:
            problems.append(f"preinst does not declare schema version {schema_version}")

    postinst = control_members.get("./postinst")
    if postinst is not None:
        body = contents(control, postinst).decode("utf-8", "replace")
        if 'spark-installer" seed-catalogue' not in body:
            problems.append("postinst does not seed the signed bootstrap catalogue")

    problems.extend(check_units(data))

    # md5sums must cover every regular file, or dpkg cannot detect tampering.
    md5sums = control_members.get("./md5sums")
    if md5sums is not None:
        recorded_lines = contents(control, md5sums).decode("utf-8").splitlines()
        listed = {line.split("  ", 1)[1] for line in recorded_lines if "  " in line}
        expected = {name[2:] for name, member in data_members.items() if member.isreg()}
        missing = expected - listed
        if missing:
            problems.append(f"md5sums omits {len(missing)} file(s): {sorted(missing)[:3]}")
        by_name = {
            line.split("  ", 1)[1]: line.split("  ", 1)[0]
            for line in recorded_lines
            if "  " in line
        }
        for name in sorted(expected & listed):
            digest = hashlib.md5(contents(data, data_members["./" + name])).hexdigest()
            if digest != by_name[name]:
                problems.append(f"md5sum mismatch for {name}")

    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Inspect a Debian binary package.")
    parser.add_argument("--deb", required=True, type=Path)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--expect-manifest", action="store_true")
    parser.add_argument("--schema-version")
    arguments = parser.parse_args(argv)

    members = read_ar(arguments.deb)

    order = list(members)
    if order[:1] != ["debian-binary"]:
        fail(f"first ar member is {order[:1]}, expected debian-binary")
    if members["debian-binary"] != b"2.0\n":
        fail("debian-binary must be exactly '2.0\\n'")
    for name in ("control.tar.xz", "data.tar.xz"):
        if name not in members:
            fail(f"missing ar member {name}")

    control = read_tar(members["control.tar.xz"])
    data = read_tar(members["data.tar.xz"])

    fields = parse_control(contents(control, "./control").decode("utf-8"))
    for required in ("Package", "Version", "Architecture", "Maintainer", "Description"):
        if required not in fields:
            fail(f"control is missing {required}")
    if fields["Architecture"] != "arm64":
        fail(f"architecture is {fields['Architecture']}, expected arm64")

    print(f"package: {fields['Package']} {fields['Version']} {fields['Architecture']}")
    print(f"installed-size: {fields.get('Installed-Size', '?')} KiB")
    print(f"depends: {fields.get('Depends', '')}")
    # The runtime execs these; the package must say so rather than rely on the DGX OS image (M-5).
    required_depends = (
        "docker.io | docker-ce",
        "nvidia-container-toolkit",
        "network-manager",
        "iproute2",
        "sqlite3",
        "nftables",
    )
    missing_depends = [name for name in required_depends if name not in fields.get("Depends", "")]
    if missing_depends:
        fail(f"control Depends is missing {', '.join(missing_depends)}")

    if arguments.list:
        for member in data.getmembers():
            kind = "d" if member.isdir() else "-"
            print(f"{kind} {member.mode:04o} {member.size:>10} {member.name}")

    if arguments.expect_manifest:
        problems = check_manifest(data, control, arguments.schema_version)
        if problems:
            for problem in problems:
                print(f"  FAIL {problem}", file=sys.stderr)
            fail(f"{len(problems)} package content problem(s)")
        files = sum(1 for member in data.getmembers() if member.isreg())
        print(f"contents ok: {files} files, every required path present, nothing forbidden")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
