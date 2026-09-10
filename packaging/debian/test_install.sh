#!/usr/bin/env bash
# Run real dpkg in a throwaway aarch64 Debian container; systemd activation/health/restart checks require a systemd host.
set -euo pipefail

DEB="${1:?usage: test_install.sh PACKAGE.deb [UPGRADE.deb]}"
UPGRADE_DEB="${2:-}"

STATE_DIR=/var/lib/spark-runtime
PRIVD_STATE_DIR=/var/lib/spark-privd
CONF_DIR=/etc/spark-runtime
CACHE_DIR=/var/cache/spark-runtime
LIB_DIR=/usr/lib/spark-runtime

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_ROOT/tests/install_support.sh"


step "1. clean install"
# The lab container has no Docker, NVIDIA runtime or NetworkManager; dependency metadata is asserted by inspect_deb.py instead.
dpkg -i --force-depends "$DEB"

getent group sparkd >/dev/null || fail "the sparkd group was not created"
pass "sparkd group created"
getent passwd sparkd >/dev/null || fail "the sparkd user was not created"
pass "sparkd user created"
shell="$(getent passwd sparkd | cut -d: -f7)"
case "$shell" in
  */nologin|*/false) pass "sparkd has no login shell ($shell)" ;;
  *) fail "sparkd has a login shell: $shell" ;;
esac

for binary in sparkd spark-privd spark-installer spark-updater; do
  require_file "$LIB_DIR/$binary"
done
for unit in sparkd spark-privd spark-updater; do
  require_file "/usr/lib/systemd/system/$unit.service"
done
require_file "/usr/lib/systemd/system/spark-runtime-update@.service"
require_file "$CONF_DIR/config.toml.example"
require_file "$CONF_DIR/config.toml"
require_file /usr/share/spark-runtime/package-version
require_owner /usr/share/spark-runtime/package-version "root:root"
require_mode /usr/share/spark-runtime/package-version 644
[ "$(cat /usr/share/spark-runtime/package-version)" = "$(dpkg-query -W -f='${Version}' spark-runtime)" ] ||
  fail "runtime identity does not include the installed package revision"
require_file /usr/share/spark-runtime/trust/release-keys.json
require_file /usr/share/spark-runtime/trust/catalogue-root.pub
require_file /usr/share/spark-runtime/trust/service-root.pub
require_file /usr/share/spark-runtime/services/open-webui.service.json
require_file /usr/share/spark-runtime/catalog/bootstrap.json
require_dir /usr/share/spark-runtime/schema

require_owner "$STATE_DIR" "sparkd:sparkd"
require_mode "$STATE_DIR" 750
require_owner "$PRIVD_STATE_DIR" "root:sparkd"
require_mode "$PRIVD_STATE_DIR" 700
require_owner "$STATE_DIR/identity" "sparkd:sparkd"
require_mode "$STATE_DIR/identity" 700
require_owner "$STATE_DIR/catalogue" "sparkd:sparkd"
require_mode "$STATE_DIR/catalogue" 750
require_file "$STATE_DIR/catalogue/catalogue.json"
require_owner "$STATE_DIR/catalogue/catalogue.json" "sparkd:sparkd"
require_mode "$STATE_DIR/catalogue/catalogue.json" 640
cmp -s /usr/share/spark-runtime/catalog/bootstrap.json \
  "$STATE_DIR/catalogue/catalogue.json" || fail "live catalogue does not match first-install bootstrap"
pass "signed bootstrap catalogue seeded into mutable state"
require_mode "$CONF_DIR/trust" 700
require_owner "$CONF_DIR/config.toml" "root:sparkd"
require_mode "$CONF_DIR/config.toml" 640

require_file "$CONF_DIR/identity/identity.key"
require_mode "$CONF_DIR/identity/identity.key" 600
require_owner "$CONF_DIR/identity" "root:root"
require_mode "$CONF_DIR/identity" 700
[ ! -e "$STATE_DIR/identity/identity.key" ] || fail "legacy authority seed remains service-owned"
[ ! -e "$STATE_DIR/identity/node.key" ] || fail "legacy TLS seed remains service-owned"
if runuser -u sparkd -- test -r "$CONF_DIR/identity/identity.key"; then
  fail "service account can read the persistent authority seed"
fi
require_file "$STATE_DIR/runtime.db"
FIRST_NODE_ID="$(node_id)"
pass "node identity created: $FIRST_NODE_ID"
FIRST_SCHEMA="$(applied_schema)"
[ "$FIRST_SCHEMA" -gt 0 ] || fail "no migrations were applied"
pass "database migrated to schema $FIRST_SCHEMA"

# The binaries must actually run on this architecture.
"$LIB_DIR/spark-installer" --version >/dev/null || fail "spark-installer does not run"
"$LIB_DIR/spark-updater" --version >/dev/null || fail "spark-updater does not run"
"$LIB_DIR/sparkd" --help >/dev/null || fail "sparkd does not run"
"$LIB_DIR/spark-privd" --help >/dev/null || fail "spark-privd does not run"
pass "all four binaries execute"

# The health gate must be honest about a node whose services never started.
if runuser -u sparkd -- "$LIB_DIR/spark-updater" health \
     --data-dir "$STATE_DIR" --require-privileged-helper >/dev/null 2>&1; then
  fail "the health gate passed with no privileged helper running"
fi
pass "health gate fails closed without the privileged helper"

step "2. repeat install (idempotence)"
# Reinstallation must preserve operator configuration and identity-bound device grants.
echo "# operator edit" >> "$CONF_DIR/config.toml"
# Change only JSON whitespace to identify a live catalogue that reinstall must not replace.
printf '\n' >> "$STATE_DIR/catalogue/catalogue.json"
LIVE_CATALOGUE_SHA="$(sha256sum "$STATE_DIR/catalogue/catalogue.json" | cut -d' ' -f1)"
dpkg -i --force-depends "$DEB"
grep -q "operator edit" "$CONF_DIR/config.toml" || fail "reinstall overwrote the configuration"
pass "operator configuration preserved"
[ "$(sha256sum "$STATE_DIR/catalogue/catalogue.json" | cut -d' ' -f1)" = "$LIVE_CATALOGUE_SHA" ] ||
  fail "reinstall replaced the live model catalogue"
pass "live model catalogue preserved"
[ "$(node_id)" = "$FIRST_NODE_ID" ] || fail "reinstall replaced the node identity"
pass "node identity unchanged"
[ "$(applied_schema)" = "$FIRST_SCHEMA" ] || fail "reinstall changed the schema version"
pass "schema unchanged"

step "3. downgrade refusal"
# Set a future schema version to exercise refusal before dpkg replaces the outgoing installation.
sqlite3 "$STATE_DIR/runtime.db" \
  "INSERT INTO schema_migrations (version, applied_at) VALUES (9999, '2026-01-01T00:00:00Z');"
if dpkg -i --force-depends "$DEB" 2>/tmp/downgrade.log; then
  fail "dpkg accepted a package older than the database schema"
fi
grep -q "refusing to install" /tmp/downgrade.log ||
  fail "the refusal did not come from the preinst preflight: $(cat /tmp/downgrade.log)"
pass "upgrade refused while the database is ahead of the package"
require_file "$LIB_DIR/sparkd"
pass "the working installation is still in place after the refusal"
[ ! -e "$STATE_DIR/identity/identity.key" ] || fail "aborted upgrade left legacy authority behind"
[ ! -e "$STATE_DIR/identity/node.key" ] || fail "aborted upgrade left legacy TLS credentials behind"
sqlite3 "$STATE_DIR/runtime.db" "DELETE FROM schema_migrations WHERE version = 9999;"
dpkg --configure spark-runtime >/dev/null 2>&1 || true

step "4. a compromised daemon cannot redirect root's file handling"
# Check every service-controlled path against planted symlinks that could redirect root ownership or permission changes.
setup_victims() {
  rm -rf /victim-dir /victim-file
  mkdir -p /victim-dir
  echo "root-owned secret" > /victim-dir/secret
  chmod 700 /victim-dir
  chown root:root /victim-dir /victim-dir/secret
  echo "root-owned file" > /victim-file
  chmod 600 /victim-file
  chown root:root /victim-file
}

victims_untouched() {
  local where="$1"
  local dir_state file_state
  dir_state="$(stat -c '%U:%G %a' /victim-dir)"
  file_state="$(stat -c '%U:%G %a' /victim-file)"
  [ "$dir_state" = "root:root 700" ] ||
    fail "$where changed /victim-dir to $dir_state"
  [ "$file_state" = "root:root 600" ] ||
    fail "$where changed /victim-file to $file_state"
  [ "$(cat /victim-dir/secret)" = "root-owned secret" ] ||
    fail "$where altered the contents of /victim-dir/secret"
  if runuser -u sparkd -- test -r /victim-dir/secret 2>/dev/null; then
    fail "$where left /victim-dir readable by the service account"
  fi
  pass "$where left the targeted root-owned paths untouched"
}

# Each service-controlled path, pointed somewhere it must never reach.
for target_path in identity catalogue models projects runtime.db runtime.db-wal runtime.db-shm; do
  setup_victims
  case "$target_path" in
    identity|catalogue|models|projects) victim=/victim-dir ;;
    *) victim=/victim-file ;;
  esac
  # Preserve the real path so subsequent upgrade checks still prove the original identity survives.
  if [ -e "$STATE_DIR/$target_path" ]; then
    mv "$STATE_DIR/$target_path" "$STATE_DIR/.held-$target_path"
  fi
  runuser -u sparkd -- ln -s "$victim" "$STATE_DIR/$target_path"
  [ -L "$STATE_DIR/$target_path" ] || fail "could not plant a link at $target_path"

  if dpkg -i --force-depends "$DEB" 2>/tmp/redirect.log; then
    # An untouched path may allow configure to succeed, but its symlink target must remain unchanged.
    victims_untouched "installing with $target_path redirected"
  else
    grep -qiE "symbolic link|not a directory|refusing" /tmp/redirect.log ||
      fail "$target_path: refused for the wrong reason: $(cat /tmp/redirect.log)"
    pass "install refused to follow a link at $target_path"
    victims_untouched "the refused install with $target_path redirected"
  fi
  rm -f "$STATE_DIR/$target_path"
  if [ -e "$STATE_DIR/.held-$target_path" ]; then
    mv "$STATE_DIR/.held-$target_path" "$STATE_DIR/$target_path"
  fi
done

# Reject a redirected catalogue file without changing its target or the preserved live catalogue.
setup_victims
mv "$STATE_DIR/catalogue/catalogue.json" "$STATE_DIR/catalogue/.held-catalogue.json"
runuser -u sparkd -- ln -s /victim-file "$STATE_DIR/catalogue/catalogue.json"
if dpkg -i --force-depends "$DEB" 2>/tmp/catalogue-redirect.log; then
  fail "install accepted a symlinked live catalogue"
fi
grep -qiE "symbolic link|refusing" /tmp/catalogue-redirect.log ||
  fail "catalogue redirection was refused for the wrong reason: $(cat /tmp/catalogue-redirect.log)"
victims_untouched "installing with the live catalogue redirected"
rm -f "$STATE_DIR/catalogue/catalogue.json"
mv "$STATE_DIR/catalogue/.held-catalogue.json" "$STATE_DIR/catalogue/catalogue.json"
pass "catalogue seeding refuses a redirected live file"

# Apply the same symlink protection to the cache tree.
setup_victims
if [ -e "${CACHE_DIR:?}/downloads" ]; then
  mv "$CACHE_DIR/downloads" "$CACHE_DIR/.held-downloads"
fi
runuser -u sparkd -- ln -s /victim-dir "$CACHE_DIR/downloads"
dpkg -i --force-depends "$DEB" >/tmp/redirect.log 2>&1 || true
victims_untouched "installing with the download cache redirected"
rm -f "$CACHE_DIR/downloads"
if [ -e "$CACHE_DIR/.held-downloads" ]; then
  mv "$CACHE_DIR/.held-downloads" "$CACHE_DIR/downloads"
fi

# Put the node back together for the remaining steps.
setup_victims
dpkg -i --force-depends "$DEB" >/dev/null 2>&1 || dpkg --configure spark-runtime >/dev/null 2>&1 || true
require_dir "$STATE_DIR/identity"
require_owner "$STATE_DIR/identity" "sparkd:sparkd"
require_mode "$STATE_DIR/identity" 700
pass "the node's directories are restored after the adversarial cases"
[ "$(node_id)" = "$FIRST_NODE_ID" ] ||
  fail "the adversarial cases re-keyed the node"
pass "the node identity survived the adversarial cases"

step "5. a compromised daemon cannot redirect the upgrade backup"
SENTINEL=/root/sentinel.txt
echo "original root-owned content" > "$SENTINEL"
chmod 600 "$SENTINEL"
mv "$STATE_DIR/runtime.db" "$STATE_DIR/runtime.db.real"
runuser -u sparkd -- ln -s "$SENTINEL" "$STATE_DIR/runtime.db"
[ -L "$STATE_DIR/runtime.db" ] || fail "the test could not plant the symlink"

if dpkg -i --force-depends "$DEB" 2>/tmp/symlink.log; then
  fail "the upgrade proceeded with a symlinked database"
fi
grep -qiE "symbolic link|refusing" /tmp/symlink.log ||
  fail "the refusal did not name the link: $(cat /tmp/symlink.log)"
pass "upgrade refused to follow a symlinked database"
grep -q "original root-owned content" "$SENTINEL" || fail "the sentinel file was modified"
[ "$(stat -c '%U:%G %a' "$SENTINEL")" = "root:root 600" ] ||
  fail "the sentinel file's ownership or mode changed"
pass "the targeted root-owned file is untouched"

rm -f "$STATE_DIR/runtime.db"
mv "$STATE_DIR/runtime.db.real" "$STATE_DIR/runtime.db"
dpkg --configure spark-runtime >/dev/null 2>&1 || dpkg -i --force-depends "$DEB" >/dev/null

step "6. upgrade backups are out of the daemon's reach"
dpkg -i --force-depends "$DEB" >/dev/null
require_dir /var/backups/spark-runtime
require_owner /var/backups/spark-runtime "root:root"
require_mode /var/backups/spark-runtime 700
latest="$(newest_backup)"
[ -n "$latest" ] || fail "no backup was taken"
require_owner "$latest" "root:root"
require_file "$latest/runtime.db"
require_owner "$latest/runtime.db" "root:root"
if runuser -u sparkd -- test -r "$latest/runtime.db" 2>/dev/null; then
  fail "sparkd can read the rollback snapshot"
fi
pass "sparkd cannot read the rollback snapshot"
if runuser -u sparkd -- test -w /var/backups/spark-runtime 2>/dev/null; then
  fail "sparkd can write into the backup root"
fi
pass "sparkd cannot write into the backup root"
[ ! -e "$STATE_DIR/.upgrade-backup" ] ||
  fail "the upgrade marker is inside a directory sparkd can write"
pass "no upgrade marker in daemon-writable storage"

step "7. an upgrade will not migrate underneath a live daemon"
# Start real sparkd without systemd to verify uid-based refusal; exec avoids killing only a wrapper while leaving the daemon alive.
install -d -o sparkd -g sparkd -m 0750 /tmp/live-node
runuser -u sparkd -- sh -c 'exec "$0" --data-dir /tmp/live-node --no-tls --no-advertise \
  --listen 127.0.0.1:17443' "$LIB_DIR/sparkd" >/tmp/live-sparkd.log 2>&1 &
LIVE_PID=$!

# Wait for the daemon to be up, not merely for the wrapper to exist.
for _ in $(seq 1 20); do
  if grep -q "serving plain HTTP" /tmp/live-sparkd.log 2>/dev/null; then break; fi
  sleep 0.5
done
grep -q "serving plain HTTP" /tmp/live-sparkd.log ||
  fail "the test could not start a live sparkd: $(cat /tmp/live-sparkd.log)"
pass "a live sparkd is running as the service account"

if dpkg -i --force-depends "$DEB" 2>/tmp/live.log; then
  fail "the upgrade proceeded while a process was running as sparkd"
fi
grep -qE "refusing to (upgrade Spark Runtime|prepare Spark Runtime package replacement) while Spark Runtime is still running" /tmp/live.log ||
  fail "wrong refusal: $(cat /tmp/live.log)"
pass "upgrade refused while a process was running as the service account"

stop_live_daemon
# Diagnose surviving harness processes before they make a recovery install fail for an unrelated reason.
remaining="$(service_account_processes)"
if [ -n "$remaining" ]; then
  for pid in $remaining; do
    printf '  still running: %s %s\n' "$pid" \
      "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" >&2
  done
  fail "the harness could not stop every process owned by the service account"
fi
dpkg --configure spark-runtime >/dev/null 2>&1 || dpkg -i --force-depends "$DEB" >/dev/null
pass "the node is installable again once nothing is running as the service account"

# Hold an exited service-uid child unreaped under a root holder that never waits, to prove zombies alone cannot block upgrades.
ZOMBIE_UID="$(id -u sparkd)"
ZOMBIE_GID="$(id -g sparkd)"
setsid sh -c "setpriv --reuid=$ZOMBIE_UID --regid=$ZOMBIE_GID --clear-groups sleep 0 & exec sleep 30" >/dev/null 2>&1 &
ZOMBIE_PARENT=$!
zombie=""
for _ in $(seq 1 20); do
  service_uid="$(getent passwd sparkd | cut -d: -f3)"
  for pid_dir in /proc/[0-9]*; do
    owner="$(stat -c '%u' "$pid_dir" 2>/dev/null)" || continue
    [ "$owner" = "$service_uid" ] || continue
    state="$(awk '/^State:/ {print $2; exit}' "$pid_dir/status" 2>/dev/null || true)"
    [ "$state" = "Z" ] && zombie="${pid_dir#/proc/}"
  done
  [ -n "$zombie" ] && break
  sleep 0.25
done

# Fail if the harness cannot hold the zombie, because the intended regression was not exercised.
[ -n "$zombie" ] ||
  fail "could not hold a zombie owned by the service account open long enough to test the refusal"
pass "a zombie owned by the service account is present (pid $zombie)"
if dpkg -i --force-depends "$DEB" >/tmp/zombie.log 2>&1; then
  pass "an upgrade is not blocked by an unreaped process"
else
  cat /tmp/zombie.log >&2
  fail "the upgrade was refused because of a process that had already exited"
fi
# The parent is a session leader, so its process group carries the service-account holder and the zombie away with it.
kill -- "-$ZOMBIE_PARENT" "$ZOMBIE_PARENT" 2>/dev/null || true
wait "$ZOMBIE_PARENT" 2>/dev/null || true
stop_live_daemon

step "8. a backup captures pages that are only in the write-ahead log"
# Verify .backup retains committed WAL-only pages that separate file copies could lose on restore.
MARKER_DEVICE="wal-marker-$$"
sqlite3 "$STATE_DIR/runtime.db" \
  "INSERT INTO devices (id, display_name, platform, public_key_spki,
                        public_key_fingerprint, role, paired_at)
   VALUES ('11111111-1111-4111-8111-111111111111', '$MARKER_DEVICE', 'ios',
           x'00', 'wal-marker-fingerprint', 'observer', '2026-08-27T00:00:00Z');"
[ -f "$STATE_DIR/runtime.db-wal" ] && pass "the live database has a write-ahead log" \
  || pass "the live database has no separate write-ahead log at this moment"

dpkg -i --force-depends "$DEB" >/dev/null
latest="$(newest_backup)"
require_file "$latest/runtime.db"
[ ! -e "$latest/runtime.db-wal" ] ||
  fail "the snapshot carries a separate write-ahead log; it is not self-contained"
pass "the snapshot is a single self-contained file"

found="$(sqlite3 "$latest/runtime.db" \
  "SELECT display_name FROM devices WHERE display_name = '$MARKER_DEVICE';")"
[ "$found" = "$MARKER_DEVICE" ] ||
  fail "the committed row is missing from the snapshot: got '$found'"
pass "a row committed just before the upgrade is in the snapshot"

# Recover with the installer command used by postinst rather than a test-only copy implementation.
sqlite3 "$STATE_DIR/runtime.db" "DELETE FROM devices WHERE display_name = '$MARKER_DEVICE';"
gone="$(sqlite3 "$STATE_DIR/runtime.db" \
  "SELECT COUNT(*) FROM devices WHERE display_name = '$MARKER_DEVICE';")"
[ "$gone" = "0" ] || fail "the test could not remove the marker row"

# Restore must unlink stale WAL files and planted WAL symlinks without following either.
: > "$STATE_DIR/runtime.db-wal"
rm -f "$STATE_DIR/runtime.db-shm"
echo "root-owned" > /victim-file 2>/dev/null || true
chmod 600 /victim-file; chown root:root /victim-file
rm -f "$STATE_DIR/runtime.db-shm"
runuser -u sparkd -- ln -s /victim-file "$STATE_DIR/runtime.db-shm"

"$LIB_DIR/spark-installer" restore-state \
  --backup "$latest" --data-dir "$STATE_DIR" --conf-dir "$CONF_DIR" \
  --user sparkd --group sparkd >/dev/null ||
  fail "restore-state failed"

restored="$(sqlite3 "$STATE_DIR/runtime.db" \
  "SELECT display_name FROM devices WHERE display_name = '$MARKER_DEVICE';")"
[ "$restored" = "$MARKER_DEVICE" ] ||
  fail "the restore lost the committed row: got '$restored'"
pass "restore-state recovers the committed row"

[ ! -e "$STATE_DIR/runtime.db-wal" ] || fail "the stale write-ahead log survived the restore"
[ ! -e "$STATE_DIR/runtime.db-shm" ] || fail "the symlinked shared-memory file survived"
pass "the restore cleared the stale write-ahead log and the planted link"
[ "$(stat -c '%U:%G %a' /victim-file)" = "root:root 600" ] ||
  fail "the restore changed the link's target"
[ "$(cat /victim-file)" = "root-owned" ] || fail "the restore wrote through the link"
pass "the restore did not follow the planted link"
require_owner "$STATE_DIR/runtime.db" "sparkd:sparkd"

sqlite3 "$STATE_DIR/runtime.db" "DELETE FROM devices WHERE display_name = '$MARKER_DEVICE';"
dpkg --configure spark-runtime >/dev/null 2>&1 || true

if [ -n "$UPGRADE_DEB" ]; then
  step "9. upgrade"
  dpkg -i --force-depends "$UPGRADE_DEB"
  [ "$(cat /usr/share/spark-runtime/package-version)" = "$(dpkg-query -W -f='${Version}' spark-runtime)" ] ||
    fail "runtime identity did not advance with the upgraded package"
  [ "$(node_id)" = "$FIRST_NODE_ID" ] || fail "the upgrade replaced the node identity"
  pass "node identity survived the upgrade"
  backups="$(find /var/backups/spark-runtime -maxdepth 1 -name 'upgrade-*' -type d | wc -l)"
  [ "$backups" -ge 1 ] || fail "the upgrade made no backup"
  pass "upgrade backed up the database and configuration"
  latest="$(newest_backup)"
  require_file "$latest/runtime.db"
  require_file "$latest/config.toml"
  [ ! -f /var/backups/spark-runtime/.pending-upgrade ] ||
    fail "the upgrade marker was not cleared on success"
  pass "upgrade committed and cleared its marker"
fi

step "10. removal keeps the node's identity"
dpkg -r spark-runtime
[ ! -f "$LIB_DIR/sparkd" ] || fail "removal left the binaries in place"
require_file "$CONF_DIR/identity/identity.key"
pass "removal kept the node identity and grants"

step "11. a purge will not delete state underneath a live process"
# Use an arbitrary service-uid child to prove purge refuses before deleting state or releasing a uid still held by a live process.
setsid runuser -u sparkd -- sleep 300 >/dev/null 2>&1 &
PURGE_BLOCKER=$!
for _ in $(seq 1 20); do
  [ -n "$(service_account_processes)" ] && break
  sleep 0.25
done
[ -n "$(service_account_processes)" ] ||
  fail "the test could not start a process owned by the service account"
pass "a process owned by the service account is running"

identity_before="$(cat "$CONF_DIR/identity/identity.key" | wc -c)"
if dpkg -P spark-runtime >/tmp/purge.log 2>&1; then
  cat /tmp/purge.log >&2
  fail "the purge deleted the node's state while a process still held its uid"
fi
pass "purge refused while a process was running as the service account"
grep -qE "refusing to purge" /tmp/purge.log ||
  fail "wrong refusal: $(cat /tmp/purge.log)"

# Refused purge must leave every protected path intact.
require_file "$CONF_DIR/identity/identity.key"
[ "$(cat "$CONF_DIR/identity/identity.key" | wc -c)" = "$identity_before" ] ||
  fail "the refused purge changed the node identity"
pass "the refused purge left the node identity intact"
require_dir "$STATE_DIR"
require_dir /var/backups/spark-runtime
pass "the refused purge left the state directory and the rollback snapshots"
getent passwd sparkd >/dev/null || fail "the refused purge removed the service account"
pass "the refused purge left the service account"

# An exited, unreaped service process must not block purge.
kill "$PURGE_BLOCKER" 2>/dev/null || true
wait "$PURGE_BLOCKER" 2>/dev/null || true
stop_live_daemon

step "12. a purge will not delete state underneath the privileged helper"
# After reinstall, start the root helper outside systemd to test kernel-executable detection when uid-only scans cannot see it.
dpkg -i --force-depends "$DEB" >/dev/null
install -d -m 0755 /run/spark-runtime
# The purge probe needs a real helper process, without Docker or firewall operations in this container.
"$LIB_DIR/spark-privd" --plan-only --socket /run/spark-runtime/privd-test.sock \
  --allowed-user sparkd --socket-group sparkd >/tmp/privd-test.log 2>&1 &
PRIVD_PID=$!
for _ in $(seq 1 20); do
  [ -S /run/spark-runtime/privd-test.sock ] && break
  sleep 0.25
done
kill -0 "$PRIVD_PID" 2>/dev/null ||
  fail "the test could not start spark-privd: $(cat /tmp/privd-test.log)"
[ "$(readlink "/proc/$PRIVD_PID/exe")" = "$LIB_DIR/spark-privd" ] ||
  fail "the started process is not the helper: $(readlink "/proc/$PRIVD_PID/exe")"
pass "the privileged helper is running as root (pid $PRIVD_PID)"

owner="$(stat -c '%u' "/proc/$PRIVD_PID")"
[ "$owner" = "0" ] || fail "the helper is not running as root; this test proves nothing"
pass "the helper is root-owned, so a service-account scan cannot see it"

identity_before="$(wc -c < "$CONF_DIR/identity/identity.key")"
if dpkg -P spark-runtime >/tmp/privd-purge.log 2>&1; then
  cat /tmp/privd-purge.log >&2
  fail "the purge deleted the node's state while the privileged helper was alive"
fi
pass "purge refused while the privileged helper was running"
grep -q "Privileged helper" /tmp/privd-purge.log ||
  fail "the refusal did not name the helper: $(cat /tmp/privd-purge.log)"

kill -0 "$PRIVD_PID" 2>/dev/null ||
  fail "the refused purge killed the helper; maintainer scripts must not kill processes"
pass "the refused purge left the helper running rather than killing it"

require_file "$CONF_DIR/identity/identity.key"
[ "$(wc -c < "$CONF_DIR/identity/identity.key")" = "$identity_before" ] ||
  fail "the refused purge changed the node identity"
pass "the refused purge left the node identity intact"
require_dir "$STATE_DIR"
require_dir /var/backups/spark-runtime
pass "the refused purge left the state directory and the rollback snapshots"
getent passwd sparkd >/dev/null || fail "the refused purge removed the service account"
pass "the refused purge left the service account"

kill "$PRIVD_PID" 2>/dev/null || true
wait "$PRIVD_PID" 2>/dev/null || true
for _ in $(seq 1 20); do
  [ -e "/proc/$PRIVD_PID/exe" ] || break
  sleep 0.25
done
rm -f /run/spark-runtime/privd-test.sock

step "13. purge clears state once nothing is running"
# An unrelated root process must neither block helper quiescence nor be killed.
setsid sleep 300 >/dev/null 2>&1 &
BYSTANDER=$!
sleep 0.5
kill -0 "$BYSTANDER" 2>/dev/null || fail "the test could not start a bystander process"
[ "$(stat -c '%u' "/proc/$BYSTANDER")" = "0" ] || fail "the bystander is not running as root"
pass "an unrelated root process is running (pid $BYSTANDER)"

dpkg -P spark-runtime
[ ! -e "$CONF_DIR/identity" ] || fail "purge left the protected node authority behind"
[ ! -e "$CONF_DIR/.identity.pending" ] || fail "purge left staged private credentials behind"
[ ! -d "$STATE_DIR" ] || fail "purge left $STATE_DIR behind"
[ ! -d "$PRIVD_STATE_DIR" ] || fail "purge left $PRIVD_STATE_DIR behind"
pass "purge removed the state directory"
getent passwd sparkd >/dev/null && fail "purge left the sparkd account behind"
pass "purge removed the service account"
[ ! -d /var/backups/spark-runtime ] || fail "purge left rollback snapshots behind"
pass "purge removed the rollback snapshots"

kill -0 "$BYSTANDER" 2>/dev/null ||
  fail "the purge killed an unrelated root process"
pass "the unrelated root process neither blocked the purge nor was killed by it"
kill "$BYSTANDER" 2>/dev/null || true
wait "$BYSTANDER" 2>/dev/null || true

step "14. a zombie does not block a purge either"
dpkg -i --force-depends "$DEB" >/dev/null
# Same holder as step 7: a root process that never waits keeps the exited service-uid child in the table.
ZOMBIE_UID="$(id -u sparkd)"
ZOMBIE_GID="$(id -g sparkd)"
setsid sh -c "setpriv --reuid=$ZOMBIE_UID --regid=$ZOMBIE_GID --clear-groups sleep 0 & exec sleep 30" >/dev/null 2>&1 &
ZOMBIE_PARENT=$!
zombie=""
for _ in $(seq 1 20); do
  service_uid="$(getent passwd sparkd | cut -d: -f3)"
  for pid_dir in /proc/[0-9]*; do
    owner="$(stat -c '%u' "$pid_dir" 2>/dev/null)" || continue
    [ "$owner" = "$service_uid" ] || continue
    state="$(awk '/^State:/ {print $2; exit}' "$pid_dir/status" 2>/dev/null || true)"
    [ "$state" = "Z" ] && zombie="${pid_dir#/proc/}"
  done
  [ -n "$zombie" ] && break
  sleep 0.25
done
[ -n "$zombie" ] ||
  fail "could not hold a zombie open long enough to test the purge gate"
pass "a zombie owned by the service account is present (pid $zombie)"

if dpkg -P spark-runtime >/tmp/zombie-purge.log 2>&1; then
  pass "a purge is not blocked by an unreaped process"
else
  cat /tmp/zombie-purge.log >&2
  fail "the purge was refused because of a process that had already exited"
fi
kill -- "-$ZOMBIE_PARENT" "$ZOMBIE_PARENT" 2>/dev/null || true
wait "$ZOMBIE_PARENT" 2>/dev/null || true
[ ! -d "$STATE_DIR" ] || fail "the purge left $STATE_DIR behind"
[ ! -d "$PRIVD_STATE_DIR" ] || fail "the purge left $PRIVD_STATE_DIR behind"
pass "purge removed the state directory"

printf '\nall install tests passed\n'
