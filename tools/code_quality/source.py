"""Discover owned source without traversing dependencies or duplicate worktrees."""

from pathlib import Path
import hashlib
import json
import subprocess

EXTENSIONS = frozenset({
    '.swift', '.rs', '.py', '.sh', '.bash', '.zsh', '.ts', '.tsx', '.mts',
    '.cts', '.js', '.jsx', '.mjs', '.cjs', '.css', '.scss', '.sql', '.c',
    '.h', '.cpp', '.cc', '.hpp', '.java', '.m', '.mm', '.S', '.html',
    '.dsl', '.yml', '.yaml', '.toml', '.jsonc', '.cu', '.cuh', '.metal',
    '.ps1', '.go', '.rb', '.lua', '.svelte', '.vue',
})
SPECIAL = frozenset({'Justfile', 'Makefile', 'Dockerfile', 'Kbuild'})
CACHE_DIRECTORIES = frozenset({
    '.build', '.git', '.next', '.venv', '__pycache__', 'node_modules',
})
OUTPUT_ROOTS = tuple(Path(value) for value in (
    'build', 'dist', 'target', 'venv', 'runtime/target',
    'apple/Vendor/SwiftTerm',  # Immutable upstream sources verified by check-development-sources.py.
))


def is_source(path: Path, prefix: bytes) -> bool:
    if any(part in CACHE_DIRECTORIES for part in path.parts):
        return False
    if any(path.is_relative_to(output) for output in OUTPUT_ROOTS):
        return False
    return (path.suffix in EXTENSIONS or path.name in SPECIAL
            or path.name.startswith('Makefile.')
            or (not path.suffix and prefix.startswith(b'#!')))


def sources(root: Path) -> list[Path]:
    vendor = root / "packaging/engines/qwen38"
    verified = set()
    if (vendor / "sources.json").exists():
        for name, digest in json.loads((vendor / "sources.json").read_text())["sha256"].items():
            path = vendor / name
            if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise ValueError(f"Qwen upstream source changed: {name}")
            verified.add(path)
    paths = subprocess.check_output([
        'git', '-C', str(root), 'ls-files', '--cached', '--others',
        '--exclude-standard', '-z',
    ]).decode('utf-8').split('\0')
    found = []
    for relative in sorted(set(paths) - {''}):
        path = root / relative
        if path in verified or path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            prefix = stream.read(2)
        if is_source(Path(relative), prefix):
            found.append(path)
    return found
