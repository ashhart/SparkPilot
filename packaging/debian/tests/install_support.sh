#!/usr/bin/env bash
# Assertions and process cleanup shared by the dpkg lifecycle scenarios.

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

LIVE_PID=""

stop_test_child() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Choose the newest snapshot by creation time because random suffixes can misorder same-second backups lexically.
newest_backup() {
  find /var/backups/spark-runtime -maxdepth 1 -name 'upgrade-*' -type d \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# Ignore exited, unreaped zombies when waiting for live service-uid processes.
service_account_processes() {
  service_uid="$(getent passwd sparkd 2>/dev/null | cut -d: -f3 || true)"
  [ -n "$service_uid" ] || return 0
  found=""
  for pid_dir in /proc/[0-9]*; do
    owner="$(stat -c '%u' "$pid_dir" 2>/dev/null)" || continue
    [ "$owner" = "$service_uid" ] || continue
    state="$(awk '/^State:/ {print $2}' "$pid_dir/status" 2>/dev/null || true)"
    [ "$state" = "Z" ] && continue
    found="$found ${pid_dir#/proc/}"
  done
  printf '%s' "${found# }"
}

# Stop and reap the test daemon and sweep service-uid survivors before later install scenarios.
stop_live_daemon() {
  if [ -n "$LIVE_PID" ]; then
    stop_test_child "$LIVE_PID"
    LIVE_PID=""
  fi

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    survivors="$(service_account_processes)"
    [ -z "$survivors" ] && break
    # shellcheck disable=SC2086
    kill $survivors 2>/dev/null || true
    sleep 0.5
  done
  if [ -n "${survivors:-}" ]; then
    # shellcheck disable=SC2086
    kill -KILL $survivors 2>/dev/null || true
  fi

  rm -rf /tmp/live-node
}

# Clean up service-account test processes on every exit path.
cleanup() {
  local status=$? pid
  trap - EXIT INT TERM
  for pid in "${PRIVD_PID:-}" "${PURGE_BLOCKER:-}" "${BYSTANDER:-}" "${ZOMBIE_PARENT:-}"; do
    stop_test_child "$pid"
  done
  stop_live_daemon >/dev/null 2>&1 || true
  return $status
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_file() { [ -f "$1" ] || fail "expected file $1"; pass "$1 exists"; }
require_dir() { [ -d "$1" ] || fail "expected directory $1"; }

require_mode() {
  local path="$1" expected="$2"
  local actual
  actual="$(stat -c '%a' "$path")"
  [ "$actual" = "$expected" ] || fail "$path has mode $actual, expected $expected"
  pass "$path mode $expected"
}

require_owner() {
  local path="$1" expected="$2"
  local actual
  actual="$(stat -c '%U:%G' "$path")"
  [ "$actual" = "$expected" ] || fail "$path is owned by $actual, expected $expected"
  pass "$path owned by $expected"
}

node_id() {
  runuser -u sparkd -- "$LIB_DIR/spark-installer" schema --data-dir "$STATE_DIR" >/dev/null
  python3 - "$STATE_DIR/identity/identity.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["node_id"])
PY
}

applied_schema() {
  runuser -u sparkd -- "$LIB_DIR/spark-installer" schema --data-dir "$STATE_DIR" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["applied"])'
}
