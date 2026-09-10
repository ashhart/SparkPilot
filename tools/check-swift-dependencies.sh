#!/usr/bin/env bash
# Match exact package pins and resolved revisions to the source lock; --update refreshes the lock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED="$ROOT/apple/Packages/SparkBootstrap/Package.resolved"
LOCK="$ROOT/docs/build/source-lock.json"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

[ -f "$RESOLVED" ] || {
  echo "error: $RESOLVED is not committed; a canonical build cannot be reproduced" >&2
  exit 1
}

python3 - "$RESOLVED" "$LOCK" "$UPDATE" "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

resolved_path, lock_path, update, root = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]

resolved = json.loads(Path(resolved_path).read_text(encoding="utf-8"))
pins = {pin["identity"]: pin for pin in resolved.get("pins", [])}
if not pins:
    print("error: Package.resolved records no pins", file=sys.stderr)
    raise SystemExit(1)

lock = json.loads(Path(lock_path).read_text(encoding="utf-8"))
recorded = lock.setdefault("swift_packages", {})

problems: list[str] = []
for identity, pin in sorted(pins.items()):
    state = pin["state"]
    want = {
        "url": pin["location"],
        "version": state.get("version"),
        "revision": state.get("revision"),
        "resolved_for": "SparkBootstrap (PR-010 SSH bootstrap)",
    }
    if want["revision"] is None:
        problems.append(f"{identity} is resolved to a branch or unpinned state")
        continue

    have = recorded.get(identity)
    if update:
        recorded[identity] = want
        continue
    if have is None:
        problems.append(f"{identity} is resolved but absent from the source lock")
    elif have.get("revision") != want["revision"] or have.get("version") != want["version"]:
        problems.append(
            f"{identity}: resolved {want['version']} ({want['revision'][:12]}) "
            f"but the source lock records {have.get('version')} "
            f"({str(have.get('revision'))[:12]})"
        )

# Anything recorded as a NIO-graph entry but no longer resolved is also stale.
for identity, entry in sorted(recorded.items()):
    if entry.get("resolved_for", "").startswith("SparkBootstrap") and identity not in pins:
        if update:
            continue
        problems.append(f"{identity} is in the source lock but no longer resolved")
if update:
    for identity in [
        identity
        for identity, entry in recorded.items()
        if entry.get("resolved_for", "").startswith("SparkBootstrap") and identity not in pins
    ]:
        del recorded[identity]

if update:
    Path(lock_path).write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    print(f"source lock updated with {len(pins)} resolved package(s)")
    raise SystemExit(0)

if problems:
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    print(
        "error: the resolved Swift dependency graph and docs/build/source-lock.json "
        "disagree. Run tools/check-swift-dependencies.sh --update and review the diff.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"swift dependencies ok: {len(pins)} package(s) match the source lock")
PY

# The manifest must not carry a version range for the remote dependency.
manifest="$ROOT/apple/Packages/SparkBootstrap/Package.swift"
if grep -qE '\.package\(url:.*(from:|\.upToNextMajor|\.upToNextMinor|branch:|revision:)' "$manifest"; then
  echo "error: $manifest uses a version range or branch for a remote dependency;" >&2
  echo "  canonical builds must resolve exactly one reviewed version (exact:)." >&2
  exit 1
fi
echo "swift dependencies ok: the remote dependency is pinned exactly"
