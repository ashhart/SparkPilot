#!/usr/bin/env bash
set -euo pipefail

SUPPORT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install_support.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

status=0
timeout --kill-after=1 10 bash -c '
  set -euo pipefail
  source "$1"
  sleep 300 & PRIVD_PID=$!
  printf "%s\n" "$PRIVD_PID" > "$2"
  fail "intentional cleanup regression probe"
' _ "$SUPPORT" "$scratch/pid" > "$scratch/log" 2>&1 || status=$?
if [ "$status" -ne 1 ]; then
  cat "$scratch/log" >&2
  echo "cleanup changed the failure status or hung: $status" >&2
  exit 1
fi
if kill -0 "$(cat "$scratch/pid")" 2>/dev/null; then
  echo "cleanup left the privileged-helper fixture running" >&2
  exit 1
fi

timeout --kill-after=1 10 bash -c '
  set -euo pipefail
  source "$1"
  sleep 300 & BYSTANDER=$!
  stop_live_daemon
  kill -0 "$BYSTANDER"
' _ "$SUPPORT"

echo "PASS: failed scenarios exit promptly, reap their helper, and preserve unrelated children during daemon cleanup"
