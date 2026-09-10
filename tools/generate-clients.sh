#!/usr/bin/env bash
# Generate committed Swift and Rust contract bindings from contracts/openapi.yaml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK=1
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

PYTHON="${CONTRACT_PYTHON:-python3}"
"$PYTHON" tools/validate_contracts.py

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spark-contracts.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
"$PYTHON" tools/generate_openapi_clients.py --output-root "$TEMP_ROOT"

GENERATED_OUTPUTS=()
while IFS= read -r line; do
    GENERATED_OUTPUTS+=("$line")
done < <(
    "$PYTHON" - "$TEMP_ROOT/contracts/generated/manifest.json" <<'PY'
import json
import sys

for output in json.load(open(sys.argv[1], encoding="utf-8"))["outputs"]:
    print(output)
PY
)

if [[ "$CHECK" -eq 1 ]]; then
    DRIFT=0
    if ! "$PYTHON" tools/check_generated_outputs.py \
        --manifest "$TEMP_ROOT/contracts/generated/manifest.json"; then
        DRIFT=1
    fi
    for output in "${GENERATED_OUTPUTS[@]}"; do
        if [[ ! -f "$output" ]]; then
            echo "missing generated output: $output" >&2
            DRIFT=1
        elif ! cmp -s "$TEMP_ROOT/$output" "$output"; then
            echo "generated output drift: $output" >&2
            diff -u "$output" "$TEMP_ROOT/$output" || true
            DRIFT=1
        fi
    done
    if [[ "$DRIFT" -ne 0 ]]; then
        echo "run ./tools/generate-clients.sh and commit the generated files" >&2
        exit 1
    fi
    echo "generated Swift and Rust contract bindings match contracts/openapi.yaml"
else
    "$PYTHON" tools/check_generated_outputs.py \
        --manifest "$TEMP_ROOT/contracts/generated/manifest.json" --remove-obsolete
    for output in "${GENERATED_OUTPUTS[@]}"; do
        mkdir -p "$(dirname "$output")"
        cp "$TEMP_ROOT/$output" "$output"
    done
    echo "generated ${#GENERATED_OUTPUTS[@]} committed contract outputs"
fi
