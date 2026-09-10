#!/bin/bash
# Run the shipping URLSession socket against sparkd's real signed WSS route.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/sparkpilot-terminal-rust}"
scratch="${SPARK_TERMINAL_SWIFT_SCRATCH:-/tmp/sparkpilot-terminal-api}"
cargo test --locked --manifest-path runtime/Cargo.toml -p sparkd --test project_flow terminal_apple_interop --no-run
swift test --package-path apple/Packages/SparkAPI --scratch-path "$scratch" --filter terminalSocketRuntimeInterop
fixture=$(mktemp -d /tmp/spark-terminal-interop.XXXXXX)
export SPARK_TERMINAL_INTEROP_DIRECTORY="$fixture"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
    # Fixture credentials belong only to the ephemeral in-memory test database.
    find "$fixture" -type f -delete
    rmdir "$fixture"
}
trap cleanup EXIT
cargo test --locked --manifest-path runtime/Cargo.toml -p sparkd --test project_flow terminal_apple_interop -- --ignored --nocapture &
server_pid=$!
for ((attempt=0; attempt<600; attempt++)); do
    [[ -f "$fixture/terminal.json" ]] && break
    kill -0 "$server_pid" 2>/dev/null || { wait "$server_pid"; exit 1; }
    sleep 0.1
done
[[ -f "$fixture/terminal.json" ]] || { echo "Runtime fixture did not become ready" >&2; exit 1; }
swift test --package-path apple/Packages/SparkAPI --scratch-path "$scratch" --skip-build --filter terminalSocketRuntimeInterop
wait "$server_pid"
server_pid=""
