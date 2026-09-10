#!/usr/bin/env bash
# Regenerate the hashed CPython 3.12 contract-tool dependency lock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PIP_VERSION="25.3"
PIP_TOOLS_VERSION="7.5.2"
PACKAGE_INDEX_URL="https://pypi.org/simple"
ENVIRONMENT=".build/contracts-lock-compiler"

command -v python3.12 >/dev/null || {
    echo "Python 3.12 is required to compile the contract dependency lock" >&2
    exit 1
}
python3.12 -m venv --clear "$ENVIRONMENT"
"$ENVIRONMENT/bin/python3" -m pip install \
    --disable-pip-version-check \
    --index-url "$PACKAGE_INDEX_URL" \
    "pip==$PIP_VERSION" \
    "pip-tools==$PIP_TOOLS_VERSION"
"$ENVIRONMENT/bin/pip-compile" \
    --generate-hashes \
    --index-url "$PACKAGE_INDEX_URL" \
    --no-emit-index-url \
    --no-header \
    --strip-extras \
    --output-file tools/requirements-contracts.txt \
    tools/requirements-contracts.in
