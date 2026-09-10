#!/usr/bin/env python3
"""Write reproducible Debian 2.0 ar and tar.xz members using only the standard library."""

from __future__ import annotations

import argparse
import hashlib
import io
import lzma
import os
import stat
import sys
import tarfile
from pathlib import Path

DEBIAN_BINARY = b"2.0\n"

# Maintainer scripts are the only control members allowed to be executable.
MAINTAINER_SCRIPTS = ("preinst", "postinst", "prerm", "postrm")
CONTROL_EXTRAS = ("conffiles", "triggers", "shlibs", "symbols")

# Use 2026-01-01T00:00:00Z when neither SOURCE_DATE_EPOCH nor git supplies a reproducible timestamp.
FALLBACK_EPOCH = 1_767_225_600


def fail(message: str) -> None:
    print(f"mkdeb: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def resolve_epoch(explicit: int | None) -> int:
    if explicit is not None:
        return explicit
    from_env = os.environ.get("SOURCE_DATE_EPOCH")
    if from_env:
        try:
            return int(from_env)
        except ValueError:
            fail(f"SOURCE_DATE_EPOCH is not an integer: {from_env!r}")
    return FALLBACK_EPOCH


def walk_tree(root: Path) -> list[Path]:
    """Return every path under `root`, parents before children, sorted."""
    entries: list[Path] = []
    for directory, subdirectories, files in os.walk(root):
        subdirectories.sort()
        files.sort()
        base = Path(directory)
        if base != root:
            entries.append(base)
        entries.extend(base / name for name in files)
    return sorted(entries, key=lambda path: path.relative_to(root).as_posix())


def normalise(info: tarfile.TarInfo, mtime: int) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = mtime
    return info


def restrict(base: int, path: Path) -> int:
    """Start from the base mode and let the source drop group/other bits; it can never add write or setuid bits."""
    source = path.stat().st_mode & 0o777
    # Owner bits come from the base so a read-only checkout still installs root-writable files.
    return (base & 0o700) | (base & source & 0o077)


def add_tree(archive: tarfile.TarFile, root: Path, mtime: int) -> None:
    root_info = archive.gettarinfo(str(root), arcname="./")
    root_info.mode = 0o755
    archive.addfile(normalise(root_info, mtime))

    for path in walk_tree(root):
        arcname = "./" + path.relative_to(root).as_posix()
        if path.is_symlink():
            fail(f"symlinks are not supported in the package tree: {arcname}")
        info = archive.gettarinfo(str(path), arcname=arcname)
        if info.isdir():
            info.mode = restrict(0o755, path)
        elif info.isreg():
            executable = bool(path.stat().st_mode & stat.S_IXUSR)
            info.mode = restrict(0o755 if executable else 0o644, path)
        else:
            fail(f"unsupported file type in the package tree: {arcname}")
        normalise(info, mtime)
        if info.isreg():
            with path.open("rb") as handle:
                archive.addfile(info, handle)
        else:
            archive.addfile(info)


def add_bytes(
    archive: tarfile.TarFile,
    name: str,
    payload: bytes,
    mode: int,
    mtime: int,
) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    info.mode = mode
    info.type = tarfile.REGTYPE
    normalise(info, mtime)
    archive.addfile(info, io.BytesIO(payload))


def compress(raw: bytes) -> bytes:
    """xz-compress with the CRC32 check dpkg-deb uses."""
    compressor = lzma.LZMACompressor(
        format=lzma.FORMAT_XZ,
        check=lzma.CHECK_CRC32,
        preset=6,
    )
    return compressor.compress(raw) + compressor.flush()


def build_data_archive(root: Path, mtime: int) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(
        fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT
    ) as archive:
        add_tree(archive, root, mtime)
    return buffer.getvalue()


def md5sums(root: Path) -> bytes:
    lines: list[bytes] = []
    for path in walk_tree(root):
        if not path.is_file() or path.is_symlink():
            continue
        digest = hashlib.md5(path.read_bytes()).hexdigest()
        relative = path.relative_to(root).as_posix()
        lines.append(f"{digest}  {relative}\n".encode("utf-8"))
    return b"".join(lines)


def installed_size_kib(root: Path) -> int:
    """Approximate `du -k` over the staged tree, as dpkg-deb records it."""
    total = 0
    for path in walk_tree(root):
        if path.is_dir():
            total += 1
            continue
        size = path.stat().st_size
        total += max(1, -(-size // 1024))
    return total


def render_control(template: Path, version: str, architecture: str, size: int) -> bytes:
    text = template.read_text(encoding="utf-8")
    for placeholder in ("@VERSION@", "@ARCHITECTURE@", "@INSTALLED_SIZE@"):
        if placeholder not in text:
            fail(f"control template is missing {placeholder}")
    text = (
        text.replace("@VERSION@", version)
        .replace("@ARCHITECTURE@", architecture)
        .replace("@INSTALLED_SIZE@", str(size))
    )
    if not text.endswith("\n"):
        text += "\n"
    return text.encode("utf-8")


def build_control_archive(
    control_dir: Path,
    data_root: Path,
    version: str,
    architecture: str,
    mtime: int,
) -> bytes:
    template = control_dir / "control.in"
    if not template.is_file():
        fail(f"missing control template: {template}")

    control = render_control(
        template, version, architecture, installed_size_kib(data_root)
    )

    buffer = io.BytesIO()
    with tarfile.open(
        fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT
    ) as archive:
        root_info = tarfile.TarInfo("./")
        root_info.type = tarfile.DIRTYPE
        root_info.mode = 0o755
        archive.addfile(normalise(root_info, mtime))

        add_bytes(archive, "./control", control, 0o644, mtime)
        add_bytes(archive, "./md5sums", md5sums(data_root), 0o644, mtime)

        for name in CONTROL_EXTRAS:
            path = control_dir / name
            if path.is_file():
                add_bytes(archive, f"./{name}", path.read_bytes(), 0o644, mtime)

        for name in MAINTAINER_SCRIPTS:
            path = control_dir / name
            if path.is_file():
                add_bytes(archive, f"./{name}", path.read_bytes(), 0o755, mtime)

    return buffer.getvalue()


def ar_member(name: str, payload: bytes, mtime: int) -> bytes:
    if len(name) > 15:
        fail(f"ar member name is too long: {name}")
    header = (
        name.ljust(16)
        + str(mtime).ljust(12)
        + "0".ljust(6)
        + "0".ljust(6)
        + "100644".ljust(8)
        + str(len(payload)).ljust(10)
        + "`\n"
    ).encode("ascii")
    if len(header) != 60:
        fail(f"internal error: ar header is {len(header)} bytes")
    padding = b"\n" if len(payload) % 2 else b""
    return header + payload + padding


def write_deb(output: Path, members: list[tuple[str, bytes]], mtime: int) -> None:
    with output.open("wb") as handle:
        handle.write(b"!<arch>\n")
        for name, payload in members:
            handle.write(ar_member(name, payload, mtime))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Write a Debian binary package.")
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--mtime", type=int, default=None)
    arguments = parser.parse_args(argv)

    root: Path = arguments.root
    control_dir: Path = arguments.control
    if not root.is_dir():
        fail(f"staged tree is not a directory: {root}")
    if not control_dir.is_dir():
        fail(f"control directory is not a directory: {control_dir}")

    mtime = resolve_epoch(arguments.mtime)

    data = build_data_archive(root, mtime)
    control = build_control_archive(
        control_dir, root, arguments.version, arguments.architecture, mtime
    )

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    write_deb(
        arguments.output,
        [
            ("debian-binary", DEBIAN_BINARY),
            ("control.tar.xz", compress(control)),
            ("data.tar.xz", compress(data)),
        ],
        mtime,
    )

    digest = hashlib.sha256(arguments.output.read_bytes()).hexdigest()
    print(f"wrote {arguments.output} ({arguments.output.stat().st_size} bytes)")
    print(f"sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
