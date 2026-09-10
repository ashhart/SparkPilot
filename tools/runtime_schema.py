"""Load the ordered SQLite shell schema entry without changing statement bytes."""

from pathlib import Path, PurePosixPath


def load_runtime_schema(root: Path) -> str:
    root = root.resolve()
    entry = root / "database/runtime-schema.sql"
    parts = []
    seen = set()
    for line in entry.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("--"):
            continue
        fields = line.split()
        if len(fields) != 2 or fields[0] != ".read":
            raise ValueError(f"Unsupported runtime schema directive: {line}")
        relative = PurePosixPath(fields[1])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Runtime schema fragment must stay inside database/schema: {relative}")
        path = (root / relative).resolve()
        if not path.is_relative_to(root / "database/schema") or path.suffix != ".sql":
            raise ValueError(f"Runtime schema fragment must stay inside database/schema: {relative}")
        if path in seen:
            raise ValueError(f"Duplicate runtime schema fragment: {relative}")
        seen.add(path)
        parts.append(path.read_text(encoding="utf-8"))
    if not parts:
        raise ValueError("Runtime schema has no fragments")
    return "".join(parts)
