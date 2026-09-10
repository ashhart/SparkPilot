#!/usr/bin/env bash
# Use Debian bookworm systemd-analyze to verify the target parser and required unit hardening.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_DIR="$ROOT/packaging/systemd"

command -v systemd-analyze >/dev/null 2>&1 || {
  echo "verify_units: systemd-analyze is required" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Supply inert ExecStart files because systemd-analyze validates path existence without executing them.
install -d "$tmp/usr/lib/spark-runtime" "$tmp/etc/spark-runtime"
for binary in sparkd spark-privd spark-updater; do
  : > "$tmp/usr/lib/spark-runtime/$binary"
  chmod 0755 "$tmp/usr/lib/spark-runtime/$binary"
done
: > "$tmp/etc/spark-runtime/config.toml"

# Verify path-rewritten copies under a temporary root so the check remains unprivileged.
for unit in sparkd spark-privd spark-updater; do
  sed \
    -e "s#/usr/lib/spark-runtime#$tmp/usr/lib/spark-runtime#g" \
    -e "s#/etc/spark-runtime#$tmp/etc/spark-runtime#g" \
    "$UNIT_DIR/$unit.service" > "$tmp/$unit.service"
done
sed \
  -e "s#/usr/lib/spark-runtime#$tmp/usr/lib/spark-runtime#g" \
  "$UNIT_DIR/spark-runtime-update@.service" > "$tmp/spark-runtime-update@.service"

systemd-analyze verify \
  "$tmp/sparkd.service" \
  "$tmp/spark-privd.service" \
  "$tmp/spark-updater.service" \
  "$tmp/spark-runtime-update@.service"

require_directive() {
  local unit="$1" directive="$2"
  local actual
  actual="$(sed -n "/^[[:space:]]*${directive%%=*}[[:space:]]*=/p" "$UNIT_DIR/$unit.service")"
  [ "$actual" = "$directive" ] || {
    echo "verify_units: $unit.service must contain $directive" >&2
    exit 1
  }
}

# Only spark-privd needs CAP_NET_RAW for ARP probes and CAP_NET_ADMIN for transaction-owned cluster firewall changes.
for unit in sparkd spark-updater; do
  require_directive "$unit" "CapabilityBoundingSet="
done
require_directive "spark-privd" "CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN"
require_directive "spark-privd" \
  "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK AF_PACKET"
require_directive "spark-privd" "StateDirectory=spark-privd"
require_directive "spark-privd" "StateDirectoryMode=0700"
for unit in sparkd spark-privd spark-updater; do
  require_directive "$unit" "NoNewPrivileges=yes"
  require_directive "$unit" "ProtectProc=invisible"
  require_directive "$unit" "ProtectSystem=strict"
  require_directive "$unit" "RestrictNamespaces=yes"
done

for unit in spark-privd spark-updater; do
  require_directive "$unit" "PrivateDevices=yes"
done
# Allow required NVIDIA telemetry nodes while the closed device policy denies other physical devices.
require_directive "sparkd" "PrivateDevices=no"
require_directive "sparkd" "DevicePolicy=closed"
expected_devices="$(printf '%s\n' \
  'DeviceAllow=/dev/nvidiactl rw' \
  'DeviceAllow=/dev/nvidia0 rw' \
  'DeviceAllow=/dev/nvidia-uvm rw' \
  'DeviceAllow=/dev/nvidia-uvm-tools rw' \
  'DeviceAllow=/dev/nvidia-modeset rw')"
actual_devices="$(sed -n '/^[[:space:]]*DeviceAllow[[:space:]]*=/p' "$UNIT_DIR/sparkd.service")"
[ "$actual_devices" = "$expected_devices" ] || {
  echo "verify_units: sparkd must allow only the five configured NVIDIA device nodes" >&2
  exit 1
}

grep -Fxq \
  "ReadWritePaths=/run/spark-runtime /var/lib/spark-runtime /var/lib/spark-privd /etc/spark-runtime" \
  "$UNIT_DIR/spark-privd.service" || {
  echo "verify_units: spark-privd must be able to write its dedicated rollback state" >&2
  exit 1
}

update_state_root="$({
  sed -n 's#^pub const DEFAULT_STATE_ROOT: &str = "\([^"]*\)";#\1#p' \
    "$ROOT/runtime/crates/spark-privd/src/update/policy.rs"
})"
[ -n "$update_state_root" ] || {
  echo "verify_units: could not read the runtime-update state root" >&2
  exit 1
}
update_state_writable=false
for writable in $(sed -n 's/^ReadWritePaths=//p' "$UNIT_DIR/spark-privd.service"); do
  case "$update_state_root/" in
    "$writable/"*) update_state_writable=true ;;
  esac
done
[ "$update_state_writable" = true ] || {
  echo "verify_units: spark-privd ProtectSystem blocks runtime-update state at $update_state_root" >&2
  exit 1
}

grep -Fxq \
  "ExecStart=/usr/lib/spark-runtime/spark-updater worker --release-id %i" \
  "$UNIT_DIR/spark-runtime-update@.service" || {
  echo "verify_units: update worker must use the fixed worker argv" >&2
  exit 1
}
grep -Fxq "User=root" "$UNIT_DIR/spark-runtime-update@.service" || {
  echo "verify_units: update worker must run as root" >&2
  exit 1
}
if grep -Eq '^(NoNewPrivileges=yes|CapabilityBoundingSet=|ProtectSystem=strict)$' \
  "$UNIT_DIR/spark-runtime-update@.service"; then
  echo "verify_units: update worker cannot be stripped of package-manager privileges" >&2
  exit 1
fi

echo "systemd units parse and required hardening is present"
