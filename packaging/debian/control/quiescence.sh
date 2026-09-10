# Build-time injection shares one gate: scan the service uid for arbitrary children and identify the root helper by unit or kernel executable.

# Find a live service-uid process of any name, excluding zombies that cannot execute or race filesystem changes.
spark_service_account_pid() {
  _sq_uid="$(getent passwd "$RUNTIME_USER" 2>/dev/null | cut -d: -f3)"
  [ -n "$_sq_uid" ] || return 1
  for _sq_dir in /proc/[0-9]*; do
    _sq_owner="$(stat -c '%u' "$_sq_dir" 2>/dev/null)" || continue
    [ "$_sq_owner" = "$_sq_uid" ] || continue
    _sq_state="$(awk '/^State:/ {print $2; exit}' "$_sq_dir/status" 2>/dev/null)" || _sq_state=""
    [ "$_sq_state" = "Z" ] && continue
    return 0
  done
  return 1
}

# Every live process owned by the service account, for a diagnostic.
spark_service_account_pids() {
  _sq_uid="$(getent passwd "$RUNTIME_USER" 2>/dev/null | cut -d: -f3)"
  [ -n "$_sq_uid" ] || return 0
  for _sq_dir in /proc/[0-9]*; do
    _sq_owner="$(stat -c '%u' "$_sq_dir" 2>/dev/null)" || continue
    [ "$_sq_owner" = "$_sq_uid" ] || continue
    _sq_state="$(awk '/^State:/ {print $2; exit}' "$_sq_dir/status" 2>/dev/null)" || _sq_state=""
    [ "$_sq_state" = "Z" ] && continue
    printf '%s %s\n' "${_sq_dir#/proc/}" \
      "$(cat "$_sq_dir/comm" 2>/dev/null || echo unknown)"
  done
}

# Match kernel-maintained /proc/<pid>/exe exactly, including the deleted-binary suffix after package removal.
spark_helper_pids() {
  for _sq_dir in /proc/[0-9]*; do
    _sq_exe="$(readlink "$_sq_dir/exe" 2>/dev/null)" || continue
    case "$_sq_exe" in
      "$PRIVD_PATH" | "$PRIVD_PATH (deleted)")
        _sq_state="$(awk '/^State:/ {print $2; exit}' "$_sq_dir/status" 2>/dev/null)" ||
          _sq_state=""
        [ "$_sq_state" = "Z" ] && continue
        printf '%s %s\n' "${_sq_dir#/proc/}" "$_sq_exe"
        ;;
    esac
  done
}

# Check the supervised unit first, then /proc for helpers started outside it or surviving a unit stop.
spark_helper_alive() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet spark-privd.service 2>/dev/null; then
      spark_helper_reason="spark-privd.service is still active"
      return 0
    fi
  fi
  _sq_found="$(spark_helper_pids)"
  if [ -n "$_sq_found" ]; then
    spark_helper_reason="a process is still executing $PRIVD_PATH"
    return 0
  fi
  return 1
}

# A missing unit during purge cannot prove quiescence; the subsequent process check must fail closed.
spark_stop_units() {
  [ -d /run/systemd/system ] || return 0
  if command -v deb-systemd-invoke >/dev/null 2>&1; then
    deb-systemd-invoke stop sparkd.service >/dev/null 2>&1 || true
    deb-systemd-invoke stop spark-privd.service >/dev/null 2>&1 || true
  else
    systemctl stop sparkd.service >/dev/null 2>&1 || true
    systemctl stop spark-privd.service >/dev/null 2>&1 || true
  fi
}

# Wait for quiescence and report the blocking pid without killing a possibly reused uid; $1 names the pending operation.
spark_require_quiescent() {
  _sq_what="$1"
  spark_stop_units

  _sq_attempt=0
  while [ "$_sq_attempt" -lt 15 ]; do
    if ! spark_service_account_pid && ! spark_helper_alive; then
      return 0
    fi
    _sq_attempt=$((_sq_attempt + 1))
    sleep 1
  done

  echo "spark-runtime: refusing to $_sq_what while Spark Runtime is still running." >&2
  if spark_service_account_pid; then
    echo "  Still running as $RUNTIME_USER:" >&2
    spark_service_account_pids | sed 's/^/      /' >&2
  fi
  if spark_helper_alive; then
    echo "  Privileged helper: $spark_helper_reason" >&2
    spark_helper_pids | sed 's/^/      /' >&2
  fi
  echo "  Nothing has been deleted. Stop it and run the command again:" >&2
  echo "      sudo systemctl stop sparkd.service spark-privd.service" >&2
  exit 1
}
