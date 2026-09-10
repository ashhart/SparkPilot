#!/usr/bin/env bash
# Run only in a disposable aarch64 Debian container with both package generations available.
set -euo pipefail
legacy_deb="${1:?legacy package required}"
protected_deb="${2:?protected package required}"
installer=/usr/lib/spark-runtime/spark-installer
legacy=/var/lib/spark-runtime/identity
vault=/etc/spark-runtime/identity

dpkg -i "$legacy_deb" >/dev/null
identity_sha="$(sha256sum "$legacy/identity.key" | cut -d' ' -f1)"
dpkg -i "$protected_deb" >/dev/null
snapshot="$(find /var/backups/spark-runtime -maxdepth 1 -name 'upgrade-*' -type d | head -1)"
[ "$(sha256sum "$vault/identity.key" | cut -d' ' -f1)" = "$identity_sha" ]
[ ! -e "$legacy/identity.key" ]
tls_sha="$(sha256sum "$vault/node.key" | cut -d' ' -f1)"
if runuser -u sparkd -- test -r "$vault/identity.key"; then
  echo 'FAIL service account can read persistent node authority' >&2
  exit 1
fi

"$installer" restore-state --backup "$snapshot" --user sparkd --group sparkd >/dev/null
dpkg -i "$legacy_deb" >/dev/null
[ "$(sha256sum "$legacy/identity.key" | cut -d' ' -f1)" = "$identity_sha" ]
[ "$(sha256sum "$legacy/node.key" | cut -d' ' -f1)" = "$tls_sha" ]
[ "$(stat -c '%U:%G %a' "$legacy/identity.key")" = 'sparkd:sparkd 600' ]
dpkg -i "$protected_deb" >/dev/null
[ "$(sha256sum "$vault/identity.key" | cut -d' ' -f1)" = "$identity_sha" ]
[ "$(sha256sum "$vault/node.key" | cut -d' ' -f1)" = "$tls_sha" ]
[ ! -e "$legacy/identity.key" ]
[ ! -e "$legacy/node.key" ]
"$installer" prepare-identity >/dev/null
[ "$(sqlite3 /var/lib/spark-runtime/runtime.db 'pragma integrity_check')" = ok ]
echo 'PASS protected upgrade, legacy rollback and protected reupgrade preserve authority and TLS'
