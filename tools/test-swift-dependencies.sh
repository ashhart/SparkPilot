#!/usr/bin/env bash
# Exercise each stale-lock failure against a scratch tree to verify the dependency gate rejects it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

# A scratch tree with only what the checker reads.
scratch() {
  rm -rf "$WORK/tree"
  mkdir -p "$WORK/tree/apple/Packages/SparkBootstrap" "$WORK/tree/docs/build" "$WORK/tree/tools"
  cp "$ROOT/apple/Packages/SparkBootstrap/Package.resolved" \
     "$WORK/tree/apple/Packages/SparkBootstrap/"
  cp "$ROOT/apple/Packages/SparkBootstrap/Package.swift" \
     "$WORK/tree/apple/Packages/SparkBootstrap/"
  cp "$ROOT/docs/build/source-lock.json" "$WORK/tree/docs/build/"
  cp "$ROOT/tools/check-swift-dependencies.sh" "$WORK/tree/tools/"
}

check() { bash "$WORK/tree/tools/check-swift-dependencies.sh" "$@" >"$WORK/out" 2>&1; }

must_pass() {
  scratch
  "$@"
  if check; then pass "$DESCRIPTION"; else fail "$DESCRIPTION: $(cat "$WORK/out")"; fi
}

must_fail() {
  scratch
  "$@"
  if check; then
    fail "$DESCRIPTION: the check passed when it should have failed"
  elif grep -qi -- "$NEEDLE" "$WORK/out"; then
    pass "$DESCRIPTION"
  else
    fail "$DESCRIPTION: failed for the wrong reason: $(cat "$WORK/out")"
  fi
}

edit_lock() {
  python3 - "$WORK/tree/docs/build/source-lock.json" "$@" <<'PY'
import json, sys
path, action = sys.argv[1], sys.argv[2]
lock = json.load(open(path))
packages = lock["swift_packages"]
if action == "drop":
    del packages[sys.argv[3]]
elif action == "revision":
    packages[sys.argv[3]]["revision"] = sys.argv[4]
elif action == "version":
    packages[sys.argv[3]]["version"] = sys.argv[4]
elif action == "add-phantom":
    packages[sys.argv[3]] = {
        "url": "https://example.invalid/ghost.git",
        "version": "9.9.9",
        "revision": "f" * 40,
        "resolved_for": "SparkBootstrap (PR-010 SSH bootstrap)",
    }
json.dump(lock, open(path, "w"), indent=2)
PY
}

DESCRIPTION="the committed tree agrees with its source lock"
must_pass true

DESCRIPTION="a dependency missing from the source lock"
NEEDLE="absent from the source lock"
must_fail edit_lock drop swift-nio-ssh

DESCRIPTION="a source lock recording a different revision"
NEEDLE="but the source lock records"
must_fail edit_lock revision swift-nio-ssh "$(printf 'a%.0s' {1..40})"

DESCRIPTION="a source lock recording a different version"
NEEDLE="but the source lock records"
must_fail edit_lock version swift-nio 99.0.0

DESCRIPTION="a source lock naming a package that is no longer resolved"
NEEDLE="no longer resolved"
must_fail edit_lock add-phantom swift-ghost

DESCRIPTION="a manifest that allows a version range"
NEEDLE="version range"
must_fail sed -i.bak 's/exact: "0.15.0"/from: "0.15.0"/' \
  "$WORK/tree/apple/Packages/SparkBootstrap/Package.swift"

DESCRIPTION="a manifest pinned to a moving branch"
NEEDLE="version range"
must_fail sed -i.bak 's/exact: "0.15.0"/branch: "main"/' \
  "$WORK/tree/apple/Packages/SparkBootstrap/Package.swift"

# And the update path restores agreement rather than only reporting it.
scratch
edit_lock drop swift-nio-ssh
if check --update && check; then
  pass "--update restores agreement"
else
  fail "--update did not restore agreement: $(cat "$WORK/out")"
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall swift dependency gate tests passed\n'
