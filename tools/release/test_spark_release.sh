#!/usr/bin/env bash
# Drive every release subcommand as a process and assert both success evidence and refusal messages.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/release/spark_release.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY_DIR="$WORK/keys"
KEY_ID="test-release-key"
KEY="$KEY_DIR/$KEY_ID.ed25519"
TRUST="$WORK/release-keys.json"
ARTIFACTS="$WORK/artifacts"
MANIFEST="$ARTIFACTS/manifest.json"

failures=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }
step() { printf '\n== %s\n' "$*"; }

# Run the tool and require success.
must() {
  local what="$1"; shift
  if output="$("$@" 2>&1)"; then
    pass "$what"
  else
    fail "$what: $output"
  fi
}

# Run the tool, require failure, and require the reason to mention `needle`.
must_refuse() {
  local what="$1" needle="$2"; shift 2
  if output="$("$@" 2>&1)"; then
    fail "$what: succeeded when it should have refused"
  elif printf '%s' "$output" | grep -qi -- "$needle"; then
    pass "$what"
  else
    fail "$what: refused for the wrong reason: $output"
  fi
}

mkdir -p "$ARTIFACTS"

step "1. keygen"
python3 "$TOOL" keygen --key-id "$KEY_ID" --key-dir "$KEY_DIR" \
  --channels dev --purposes release-manifest release-package \
  --not-before 2026-01-01T00:00:00Z --not-after 2027-01-01T00:00:00Z > "$TRUST"
[ -f "$KEY" ] || fail "keygen wrote no private key"
mode="$(stat -f '%Lp' "$KEY" 2>/dev/null || stat -c '%a' "$KEY")"
[ "$mode" = "600" ] && pass "private key is mode 600" || fail "private key mode is $mode"
grep -q '"purposes"' "$TRUST" && pass "trust root records key purposes" \
  || fail "trust root has no purposes"

must_refuse "keygen refuses a production channel" "offline-root" \
  python3 "$TOOL" keygen --key-id prod --key-dir "$WORK/prod-keys" --channels stable
[ ! -e "$WORK/prod-keys/prod.ed25519" ] \
  && pass "a refused keygen leaves no key material behind" \
  || fail "a refused keygen wrote a private key"

must_refuse "keygen refuses an unknown purpose" "unknown key purposes" \
  python3 "$TOOL" keygen --key-id other --key-dir "$WORK/other-keys" \
    --channels dev --purposes take-over-the-world

must_refuse "keygen refuses a backwards validity window" "not-after" \
  python3 "$TOOL" keygen --key-id backwards --key-dir "$WORK/backwards-keys" \
    --channels dev --not-before 2027-01-01T00:00:00Z --not-after 2026-01-01T00:00:00Z

must_refuse "keygen refuses to overwrite an existing key" "already exists" \
  python3 "$TOOL" keygen --key-id "$KEY_ID" --key-dir "$KEY_DIR" --channels dev

step "2. manifest and signing"
printf 'pretend this is a package\n' > "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb"
printf 'and a second one\n' > "$ARTIFACTS/spark-extras_0.1.0-1_arm64.deb"

must "manifest builds from real artifacts" \
  python3 "$TOOL" manifest \
    --artifact "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb" \
    --version 0.1.0 --channel dev \
    --base-url https://releases.example.invalid/dev \
    --minimum-dgx-os 7.0 --released-at 2026-08-27T00:00:00Z \
    --output "$MANIFEST"

must "signing covers the manifest and its artifact" \
  python3 "$TOOL" sign --manifest "$MANIFEST" \
    --artifact "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb" \
    --key "$KEY" --key-id "$KEY_ID"
[ -f "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb.sig" ] \
  && pass "a detached artifact signature was written" \
  || fail "no detached signature"

step "3. verify (the regression this file exists for)"
must "verify accepts a correctly signed release" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS"

# Require verification success output so parser failures cannot masquerade as a valid signature check.
output="$(python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
  --artifact-dir "$ARTIFACTS" 2>&1)"
printf '%s' "$output" | grep -q "manifest ok" \
  && pass "verify reports the manifest as checked" \
  || fail "verify did not confirm the manifest: $output"
printf '%s' "$output" | grep -q "digest and detached signature" \
  && pass "verify reports the artifact signature as checked" \
  || fail "verify did not confirm the artifact signature: $output"
printf '%s' "$output" | grep -qi "traceback" \
  && fail "verify raised instead of verifying: $output" \
  || pass "verify completed without an exception"

must "verify accepts an explicit --at inside the key window" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS" --at 2026-08-27T00:00:00Z

step "4. verify refuses what it must"
must_refuse "an expired key" "not valid at" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS" --at 2028-01-01T00:00:00Z

must_refuse "a key used before its window opens" "not valid at" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS" --at 2025-01-01T00:00:00Z

python3 - "$TRUST" "$WORK/revoked.json" <<'PY'
import json, sys
trust = json.load(open(sys.argv[1]))
trust["keys"][0]["revoked_at"] = "2026-06-01T00:00:00Z"
json.dump(trust, open(sys.argv[2], "w"))
PY
must_refuse "a revoked key" "revoked" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$WORK/revoked.json" \
    --artifact-dir "$ARTIFACTS"

python3 - "$TRUST" "$WORK/catalogue-only.json" <<'PY'
import json, sys
trust = json.load(open(sys.argv[1]))
trust["keys"][0]["purposes"] = ["model-catalogue"]
json.dump(trust, open(sys.argv[2], "w"))
PY
must_refuse "a catalogue key signing a release" "may not sign release manifests" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$WORK/catalogue-only.json" \
    --artifact-dir "$ARTIFACTS"

python3 - "$TRUST" "$WORK/other-channel.json" <<'PY'
import json, sys
trust = json.load(open(sys.argv[1]))
trust["keys"][0]["channels"] = ["lab"]
json.dump(trust, open(sys.argv[2], "w"))
PY
must_refuse "a key not authorised for the channel" "not authorised for channel" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$WORK/other-channel.json" \
    --artifact-dir "$ARTIFACTS"

python3 - "$MANIFEST" "$WORK/tampered.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest["artifacts"][0]["sha256"] = "0" * 64
json.dump(manifest, open(sys.argv[2], "w"))
PY
must_refuse "a tampered digest" "does not verify" \
  python3 "$TOOL" verify --manifest "$WORK/tampered.json" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS"

python3 - "$MANIFEST" "$WORK/unsigned.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest.pop("signature")
json.dump(manifest, open(sys.argv[2], "w"))
PY
must_refuse "an unsigned manifest" "no signature" \
  python3 "$TOOL" verify --manifest "$WORK/unsigned.json" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS"

mv "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb.sig" "$WORK/held.sig"
must_refuse "an artifact with no detached signature" "must be signed" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$ARTIFACTS"
mv "$WORK/held.sig" "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb.sig"

# Keep artifact length unchanged so only the digest check can detect tampering.
mkdir -p "$WORK/swapped"
printf 'PRETEND THIS IS A PACKAGE\n' > "$WORK/swapped/spark-runtime_0.1.0-1_arm64.deb"
cp "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb.sig" "$WORK/swapped/"
must_refuse "a same-length swapped artifact" "digest mismatch" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$WORK/swapped"

# And a truncated one is caught earlier still, by size.
mkdir -p "$WORK/truncated"
printf 'short\n' > "$WORK/truncated/spark-runtime_0.1.0-1_arm64.deb"
cp "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb.sig" "$WORK/truncated/"
must_refuse "a truncated artifact" "manifest says" \
  python3 "$TOOL" verify --manifest "$MANIFEST" --trust-root "$TRUST" \
    --artifact-dir "$WORK/truncated"

step "5. partial signing is refused at signing time"
must "a two-artifact manifest builds" \
  python3 "$TOOL" manifest \
    --artifact "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb" \
              "$ARTIFACTS/spark-extras_0.1.0-1_arm64.deb" \
    --version 0.1.0 --channel dev \
    --base-url https://releases.example.invalid/dev \
    --minimum-dgx-os 7.0 --released-at 2026-08-27T00:00:00Z \
    --output "$WORK/two.json"

must_refuse "signing only some of the artifacts" "every manifest artifact must be signed" \
  python3 "$TOOL" sign --manifest "$WORK/two.json" \
    --artifact "$ARTIFACTS/spark-runtime_0.1.0-1_arm64.deb" \
    --key "$KEY" --key-id "$KEY_ID"

must_refuse "signing an artifact the manifest does not list" "not listed" \
  python3 "$TOOL" sign --manifest "$MANIFEST" \
    --artifact "$ARTIFACTS/spark-extras_0.1.0-1_arm64.deb" \
    --key "$KEY" --key-id "$KEY_ID"

step "6. canonicalisation fixture"
must "the Python canonicaliser matches the shared fixture" \
  python3 "$TOOL" selftest \
    --fixture "$ROOT/contracts/fixtures/release-manifest-canonicalization.json"

step "7. the shipped dev release still verifies"
if [ -f "$ROOT/packaging/release-manifests/spark-runtime-0.1.0-dev.json" ]; then
  must "the committed manifest verifies against the committed trust root" \
    python3 "$TOOL" verify \
      --manifest "$ROOT/packaging/release-manifests/spark-runtime-0.1.0-dev.json" \
      --trust-root "$ROOT/packaging/trust/release-keys.json" \
      --manifest-only
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall release-tool tests passed\n'
