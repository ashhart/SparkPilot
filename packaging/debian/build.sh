#!/usr/bin/env bash
# Build reproducible arm64 Debian packages; usage and reproducibility controls are in packaging/debian/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${SPARK_BUILD_DIR:-$ROOT/build/packaging}"
STAGE_DIR="$BUILD_DIR/stage"
OUT_DIR="${SPARK_OUTPUT_DIR:-$BUILD_DIR/out}"
CONTROL_SRC="$ROOT/packaging/debian/control"
CONTROL_DIR="$BUILD_DIR/control"

# Pin Rust because a moving stable toolchain changes the artifact.
BUILD_IMAGE="${SPARK_BUILD_IMAGE:-rust:1.94-bookworm}"
BUILD_TOOLCHAIN="${SPARK_RUST_TOOLCHAIN:-1.94.0}"
# Bound container build concurrency to avoid lost Rust metadata on Docker Desktop bind mounts.
BUILD_JOBS="${SPARK_CARGO_BUILD_JOBS:-2}"

PACKAGE_NAME=spark-runtime
ARCHITECTURE=arm64
BINARIES=(sparkd spark-privd spark-installer spark-updater)
UNITS=(sparkd.service spark-privd.service spark-updater.service spark-runtime-update@.service)

CHECK_TREE_ONLY=0
VERIFY_REPRODUCIBLE=0
PREBUILT_BINARIES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check-tree) CHECK_TREE_ONLY=1 ;;
    --verify-reproducible) VERIFY_REPRODUCIBLE=1 ;;
    --binaries) PREBUILT_BINARIES="${2:?--binaries needs a directory}"; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: packaging/debian/build.sh [--check-tree] [--binaries DIR] [--verify-reproducible]

Cross-build and package for aarch64 Linux, or use existing binaries from DIR.
--check-tree validates packaging inputs without building or installing anything.
SOURCE_DATE_EPOCH pins timestamps; --verify-reproducible compares two package digests.
USAGE
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Package versions.

crate_version() {
  sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$ROOT/runtime/Cargo.toml" | head -1
}

# Bake the highest shipped migration into preinst so incompatible downgrades fail before unpacking.
schema_version() {
  ls "$ROOT/runtime/crates/sparkd/migrations"/*.sql \
    | sed -n 's#.*/\([0-9]\{4\}\)_.*#\1#p' \
    | sort -n | tail -1 | sed 's/^0*//'
}

source_date_epoch() {
  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    printf '%s' "$SOURCE_DATE_EPOCH"
  elif git -C "$ROOT" rev-parse >/dev/null 2>&1; then
    git -C "$ROOT" log -1 --format=%ct
  else
    printf '%s' 1767225600
  fi
}

VERSION="$(crate_version)"
DEBIAN_REVISION="${SPARK_DEBIAN_REVISION:-1}"
DEBIAN_VERSION="$VERSION-$DEBIAN_REVISION"
SCHEMA_VERSION="$(schema_version)"
DEB_NAME="${PACKAGE_NAME}_${DEBIAN_VERSION}_${ARCHITECTURE}.deb"

# Validate the staged package tree.

# Inject the shared quiescence gate so every maintainer script uses the same process-liveness rules.
assemble_control_script() {
  awk -v gate="$CONTROL_SRC/quiescence.sh" '
    $0 == "@QUIESCENCE@" {
      while ((getline line < gate) > 0) print line
      close(gate)
      next
    }
    { print }
  ' "$CONTROL_SRC/$1" | sed "s/@SCHEMA_VERSION@/$SCHEMA_VERSION/g"
}

check_tree() {
  log "validating the packaging tree"
  # A published package must fit the signed updater's release-id alphabet and length.
  [[ "$DEBIAN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9][a-z0-9.-]*$ ]] ||
    die "package version cannot be represented by a runtime update release id"
  [ "${#DEBIAN_VERSION}" -le 121 ] || die "package version exceeds the runtime update release-id limit"
  for unit in "${UNITS[@]}"; do
    [ -f "$ROOT/packaging/systemd/$unit" ] || die "missing unit: packaging/systemd/$unit"
  done
  for script in control.in quiescence.sh preinst postinst prerm postrm; do
    [ -f "$CONTROL_SRC/$script" ] || die "missing control file: $script"
  done
  sh -n "$CONTROL_SRC/quiescence.sh" || die "quiescence.sh is not valid POSIX shell"
  # Check assembled maintainer scripts because placeholder sources are not the scripts that ship.
  for script in preinst postinst prerm postrm; do
    grep -q '^@QUIESCENCE@$' "$CONTROL_SRC/$script" ||
      die "$script does not include the shared quiescence gate"
    # Require both gate identifiers to prevent a scan from silently matching the wrong account or helper.
    grep -q '^RUNTIME_USER=' "$CONTROL_SRC/$script" ||
      die "$script does not define RUNTIME_USER for the quiescence gate"
    grep -q '^PRIVD_PATH=' "$CONTROL_SRC/$script" ||
      die "$script does not define PRIVD_PATH for the quiescence gate"
    assemble_control_script "$script" | sh -n ||
      die "$script is not valid POSIX shell once assembled"
  done
  [ -f "$ROOT/packaging/trust/release-keys.json" ] || die "missing release trust root"
  [ -f "$ROOT/packaging/trust/service-root.pub" ] || die "missing service trust root"
  [ -f "$ROOT/recipes/open-webui.service.json" ] || die "missing signed Open WebUI recipe"
  [ -f "$ROOT/config/sparkd.example.toml" ] || die "missing example configuration"
  [ -n "$SCHEMA_VERSION" ] || die "could not determine the schema version"
  if grep -Eq 'systemctl enable .*\|\| true' "$CONTROL_SRC/postinst"; then
    die "postinst ignores a failed systemctl enable; the package could disappear after reboot"
  fi
  log "packaging tree complete (version $DEBIAN_VERSION, schema $SCHEMA_VERSION)"
}

check_tree
if [ "$CHECK_TREE_ONLY" = 1 ]; then
  exit 0
fi

# Cross-build for aarch64 Linux.

build_binaries() {
  local target_dir="$BUILD_DIR/target-linux-arm64"
  mkdir -p "$target_dir"

  command -v docker >/dev/null 2>&1 ||
    die "docker is required to cross-build for aarch64 Linux; or pass --binaries DIR"

  # Build the whole workspace to preserve the unified Cargo feature set used by other builds.
  log "cross-building for aarch64 Linux in $BUILD_IMAGE"
  docker run --rm \
    --platform linux/arm64 \
    -e RUSTUP_TOOLCHAIN="$BUILD_TOOLCHAIN" \
    -e CARGO_TERM_COLOR=never \
    -e CARGO_BUILD_JOBS="$BUILD_JOBS" \
    -v "$ROOT:/src:ro" \
    -v "$target_dir:/build/target" \
    -v "spark-cargo-registry:/usr/local/cargo/registry" \
    -v "spark-cargo-git:/usr/local/cargo/git" \
    -w /src/runtime \
    "$BUILD_IMAGE" \
    cargo build --release --locked --target-dir /build/target --workspace

  BINARY_DIR="$target_dir/release"
}

if [ -n "$PREBUILT_BINARIES" ]; then
  BINARY_DIR="$PREBUILT_BINARIES"
  log "using prebuilt binaries from $BINARY_DIR"
else
  build_binaries
fi

for binary in "${BINARIES[@]}"; do
  [ -f "$BINARY_DIR/$binary" ] || die "missing built binary: $BINARY_DIR/$binary"
done

# The package must not ship host binaries by accident.
if command -v file >/dev/null 2>&1; then
  for binary in "${BINARIES[@]}"; do
    description="$(file -b "$BINARY_DIR/$binary")"
    case "$description" in
      *ARM\ aarch64*|*aarch64*) ;;
      *) die "$binary is not an aarch64 ELF binary: $description" ;;
    esac
  done
  log "verified all binaries are aarch64 ELF"
fi

# Stage the required package layout (PLAN §11.5).

stage_tree() {
  rm -rf "$STAGE_DIR" "$CONTROL_DIR"
  mkdir -p "$STAGE_DIR" "$CONTROL_DIR"

  install -d -m 0755 "$STAGE_DIR/usr/lib/spark-runtime"
  for binary in "${BINARIES[@]}"; do
    install -m 0755 "$BINARY_DIR/$binary" "$STAGE_DIR/usr/lib/spark-runtime/$binary"
  done

  install -d -m 0755 "$STAGE_DIR/usr/lib/systemd/system"
  for unit in "${UNITS[@]}"; do
    install -m 0644 "$ROOT/packaging/systemd/$unit" "$STAGE_DIR/usr/lib/systemd/system/$unit"
  done

  install -d -m 0755 "$STAGE_DIR/usr/share/spark-runtime/engines"
  cp -R "$ROOT/packaging/engines/qwen38" "$STAGE_DIR/usr/share/spark-runtime/engines/"

  # Keep daemon identity aligned with dpkg even when the source version is unchanged.
  install -d -m 0755 "$STAGE_DIR/usr/share/spark-runtime"
  printf '%s\n' "$DEBIAN_VERSION" > "$STAGE_DIR/usr/share/spark-runtime/package-version"
  chmod 0644 "$STAGE_DIR/usr/share/spark-runtime/package-version"

  install -d -m 0755 "$STAGE_DIR/usr/share/spark-runtime/schema"
  install -m 0644 "$ROOT"/contracts/schemas/*.json "$STAGE_DIR/usr/share/spark-runtime/schema/"

  # Future updates verify against this installed trust root.
  install -d -m 0755 "$STAGE_DIR/usr/share/spark-runtime/trust"
  install -m 0644 "$ROOT/packaging/trust/release-keys.json" \
    "$STAGE_DIR/usr/share/spark-runtime/trust/release-keys.json"
  install -m 0644 "$ROOT/packaging/trust/catalogue-root.pub" \
    "$STAGE_DIR/usr/share/spark-runtime/trust/catalogue-root.pub"
  install -m 0644 "$ROOT/packaging/trust/service-root.pub" \
    "$STAGE_DIR/usr/share/spark-runtime/trust/service-root.pub"

  install -d -m 0755 "$STAGE_DIR/usr/share/spark-runtime/services"
  install -m 0644 "$ROOT/recipes/open-webui.service.json" \
    "$STAGE_DIR/usr/share/spark-runtime/services/open-webui.service.json"

  # Protected promotion replaces this signed bootstrap catalogue and its dedicated root independently of package/manifest signing keys.
  install -d -m 0755 "$STAGE_DIR/usr/share/spark-runtime/catalog"
  install -m 0644 "$ROOT/packaging/catalogue/bootstrap.lab.json" \
    "$STAGE_DIR/usr/share/spark-runtime/catalog/bootstrap.json"

  install -d -m 0755 "$STAGE_DIR/etc/spark-runtime"
  install -m 0644 "$ROOT/config/sparkd.example.toml" \
    "$STAGE_DIR/etc/spark-runtime/config.toml.example"

  install -d -m 0755 "$STAGE_DIR/usr/share/doc/$PACKAGE_NAME"
  install -m 0644 "$ROOT/LICENSE" "$STAGE_DIR/usr/share/doc/$PACKAGE_NAME/copyright"

  # Control scripts, with the build-time substitutions they need.
  cp "$CONTROL_SRC/control.in" "$CONTROL_DIR/control.in"
  for script in preinst postinst prerm postrm; do
    assemble_control_script "$script" > "$CONTROL_DIR/$script"
    chmod 0755 "$CONTROL_DIR/$script"
  done
}

stage_tree

# Write the Debian archive.

build_deb() {
  local output="$1"
  python3 "$ROOT/packaging/debian/mkdeb.py" \
    --root "$STAGE_DIR" \
    --control "$CONTROL_DIR" \
    --output "$output" \
    --version "$DEBIAN_VERSION" \
    --architecture "$ARCHITECTURE" \
    --mtime "$(source_date_epoch)"
}

mkdir -p "$OUT_DIR"
DEB_PATH="$OUT_DIR/$DEB_NAME"
log "writing $DEB_PATH"
build_deb "$DEB_PATH"

log "validating the package"
python3 "$ROOT/packaging/debian/inspect_deb.py" --deb "$DEB_PATH" --expect-manifest \
  --schema-version "$SCHEMA_VERSION"

if [ "$VERIFY_REPRODUCIBLE" = 1 ]; then
  log "verifying reproducibility"
  second="$BUILD_DIR/reproducibility-check.deb"
  build_deb "$second" >/dev/null
  first_digest="$(shasum -a 256 "$DEB_PATH" | cut -d' ' -f1)"
  second_digest="$(shasum -a 256 "$second" | cut -d' ' -f1)"
  rm -f "$second"
  [ "$first_digest" = "$second_digest" ] ||
    die "the package is not reproducible: $first_digest != $second_digest"
  log "reproducible: $first_digest"
fi

log "built $DEB_PATH"
printf '%s\n' "$DEB_PATH"
