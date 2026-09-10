#!/usr/bin/env bash
# Create a local iPhone-only archive; this script never exports or uploads a build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to an unused positive integer}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo "BUILD_NUMBER must be a positive integer" >&2
  exit 1
}

ARCHIVE_PYTHON="${CONTRACT_PYTHON:-$ROOT/.build/contracts-venv312/bin/python3}"
if ! "$ARCHIVE_PYTHON" -c 'import cryptography' >/dev/null 2>&1; then
  echo "Set CONTRACT_PYTHON to a Python environment with tools/requirements-contracts.txt installed." >&2
  exit 1
fi

"$ARCHIVE_PYTHON" "$ROOT/tools/catalogue/spark_catalogue.py" release-check --catalogue \
  "$ROOT/apple/SparkApp/Shared/Resources/model-presets.json"

"$ROOT/tools/check-swift-dependencies.sh"
mkdir -p "$ROOT/build/testflight"

# Preserve resource bytes in every target and verify the completed archive.
xcodebuild \
  -workspace "$ROOT/apple/Spark.xcworkspace" \
  -scheme Spark \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ROOT/build/testflight/SparkPilot-$BUILD_NUMBER.xcarchive" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SPARK_IOS_DEVICE_FAMILY=1 \
  COPY_PHASE_STRIP=NO \
  archive

"$ARCHIVE_PYTHON" "$ROOT/tools/release/check_bundled_release.py" \
  "$ROOT/build/testflight/SparkPilot-$BUILD_NUMBER.xcarchive/Products/Applications/Spark.app"

python3 "$ROOT/tools/release/check_watch_bundle.py" \
  "$ROOT/build/testflight/SparkPilot-$BUILD_NUMBER.xcarchive/Products/Applications/Spark.app"
