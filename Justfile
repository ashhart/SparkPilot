set shell := ["bash", "-euo", "pipefail", "-c"]

cargo_audit := ".build/tools/bin/cargo-audit"
cargo_audit_version := "0.22.2"
runtime_manifest := "runtime/Cargo.toml"
contract_python := ".build/contracts-venv312/bin/python3"
quality_python := ".build/quality-venv312/bin/python3"

default:
    @just --list

format:
    cargo fmt --manifest-path {{runtime_manifest}} --all
    swift format --recursive --configuration .swift-format --in-place apple/Packages apple/SparkApp

rust-format-check:
    cargo fmt --manifest-path {{runtime_manifest}} --all -- --check

swift-format-check:
    ./tools/check-swift-format.sh --all

swift-format-check-changed base="main" head="HEAD":
    ./tools/check-swift-format.sh --diff "{{base}}" "{{head}}"

format-check: rust-format-check swift-format-check

lint:
    cargo clippy --manifest-path {{runtime_manifest}} --workspace --all-targets --all-features --locked -- -D warnings

test-runtime:
    cargo test --manifest-path {{runtime_manifest}} --workspace --all-features --locked

_cargo-audit:
    if [[ ! -x {{cargo_audit}} ]] || [[ "$({{cargo_audit}} --version)" != "cargo-audit {{cargo_audit_version}}" ]]; then CARGO_INSTALL_ROOT="$PWD/.build/tools" cargo install --locked --version {{cargo_audit_version}} cargo-audit; fi

audit: _cargo-audit
    {{cargo_audit}} audit --file runtime/Cargo.lock

_contract-env:
    command -v python3.12 >/dev/null || { echo "Python 3.12 is required for contract tooling" >&2; exit 1; }
    if [[ ! -x {{contract_python}} ]] || ! {{contract_python}} -c 'import sys; raise SystemExit(sys.version_info[:2] != (3, 12))'; then python3.12 -m venv --clear .build/contracts-venv312; fi
    {{contract_python}} -m pip install --disable-pip-version-check --quiet --require-hashes -r tools/requirements-contracts.txt

test-contracts: _contract-env
    {{contract_python}} -m unittest discover -s tests/contract -p 'test_*.py'
    {{contract_python}} tools/validate_contracts.py
    CONTRACT_PYTHON="$PWD/{{contract_python}}" ./tools/generate-clients.sh --check

_quality-env:
    command -v python3.12 >/dev/null || { echo "Python 3.12 is required for source quality checks" >&2; exit 1; }
    if [[ ! -x {{quality_python}} ]] || ! {{quality_python}} -c 'import sys; raise SystemExit(sys.version_info[:2] != (3, 12))'; then python3.12 -m venv --clear .build/quality-venv312; fi
    {{quality_python}} -m pip install --disable-pip-version-check --quiet --require-hashes -r tools/requirements-quality.txt

test-code-quality: _quality-env
    {{quality_python}} -m unittest discover -s tests/code-quality -p 'test_*.py'
    {{quality_python}} tools/check_code_quality.py --notices tests/code-quality/notices.json

# Require complete matrix coverage and reject missing or stale catalogue entries.
test-matrices:
    #!/usr/bin/env bash
    set -uo pipefail
    # Every suite runs even when an earlier one fails; the recipe is red if any of them was.
    failed=0
    for suite in security integration fault-injection hardware ui model-lifecycle localisation accessibility; do
        echo "== tests/$suite"
        python3 -m unittest discover -s "tests/$suite" -p 'test_*_matrix.py' || failed=1
    done
    exit "$failed"

# Use fixed seeds and committed reduced cases to reproduce hostile-input failures.
test-fuzz-security:
    cargo test --manifest-path {{runtime_manifest}} -p sparkd --all-features --locked \
        --test api_fuzz --test signature_fuzz --test inference_proxy_fuzz
    cargo test --manifest-path {{runtime_manifest}} -p spark-privd --all-features --locked \
        --test protocol_fuzz
    # Exercise loaded-engine handlers to prove parsing and sanitizing precede admission counters.
    cargo test --manifest-path {{runtime_manifest}} -p sparkd --all-features --locked \
        --test engine_flow -- chat_body admission_checks_identity an_engine_swapped
    swift test --package-path apple/Packages/SparkTransport --filter SSEParserFuzz
    swift test --package-path apple/Packages/SparkBootstrap --filter RequestSigningFuzz

build-runtime:
    cargo build --manifest-path {{runtime_manifest}} --workspace --release --locked

package-runtime:
    ./packaging/debian/build.sh

# Sign and assemble the model catalogue, then place it in the package, the app and the website.
publish-catalogue:
    ./tools/catalogue/publish.sh

# The reviewed Swift dependency graph must reject a stale lock.
test-swift-deps:
    ./tools/check-swift-dependencies.sh
    ./tools/test-swift-dependencies.sh

# Compile probes enforce that shipping Swift callers cannot reach an unpinned Spark.
test-swift-api-surface:
    ./tools/check-swift-api-surface.sh

# PLAN §48.2's AppIntents suite: build both apps, then check the extracted metadata.
test-app-intents:
    ./tools/test-app-intents-metadata.sh

# Test every Swift package in dependency order, then compile both unsigned app targets.
test-apple-build: _contract-env
    ./tools/build-apple.sh

# Regenerate from committed lockfiles so dependency drift fails the SBOM schema gate.
test-sbom: _contract-env
    {{contract_python}} tools/generate_sbom.py --check
    {{contract_python}} -m unittest discover -s tests/sbom -p 'test_*_matrix.py'

sbom:
    python3 tools/generate_sbom.py

test-release: _contract-env
    PATH="$PWD/.build/contracts-venv312/bin:$PATH" bash tools/release/test_spark_release.sh
    {{contract_python}} tools/release/test_release_delegation.py

ci base="main" head="HEAD": test-release rust-format-check lint test-runtime test-contracts test-swift-deps test-swift-api-surface test-apple-build test-app-intents test-sbom test-fuzz-security test-matrices test-code-quality audit
    ./tools/check-swift-format.sh --diff "{{base}}" "{{head}}"
