#!/usr/bin/env bash
# Build every shared Swift package in dependency order.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Build against reviewed dependency revisions without automatic resolution or updates.
SWIFT_FLAGS=(--disable-automatic-resolution)
RELEASE_PYTHON="${CONTRACT_PYTHON:-python3}"
"$RELEASE_PYTHON" -c "import cryptography"

"$ROOT/tools/check-swift-dependencies.sh"

PACKAGES=(
  SparkCore
  SparkDiscovery
  SparkSecurity
  SparkTransport
  SparkAPI
  SparkBootstrap
  SparkLanguageModel
  SparkIntelligence
  SparkProjects
  SparkIntents
  SparkDesignSystem
  SparkLibrary
)

for package in "${PACKAGES[@]}"; do
  echo "== building $package =="
  (
    cd "$ROOT/apple/Packages/$package"
    swift build "${SWIFT_FLAGS[@]}"
    swift test "${SWIFT_FLAGS[@]}"
  )
done

echo "== building SparkApp composition =="
(
  cd "$ROOT/apple/SparkApp"
  # Rebuild composition after dependency layout or embedded release filenames change.
  swift package clean
  swift build "${SWIFT_FLAGS[@]}"
  swift test "${SWIFT_FLAGS[@]}"
)

echo "== building Spark iPhone and iPad app =="
xcodebuild \
  -workspace "$ROOT/apple/Spark.xcworkspace" \
  -scheme Spark \
  -configuration Release \
  -derivedDataPath "$ROOT/.build/apple-ci" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  clean
xcodebuild \
  -workspace "$ROOT/apple/Spark.xcworkspace" \
  -scheme Spark \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath "$ROOT/.build/apple-ci" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  build

"$RELEASE_PYTHON" "$ROOT/tools/release/check_bundled_release.py" \
  "$ROOT/.build/apple-ci/Build/Products/Release-iphoneos/Spark.app"

echo "== building Spark macOS app =="
xcodebuild \
  -workspace "$ROOT/apple/Spark.xcworkspace" \
  -scheme SparkMac \
  -destination "generic/platform=macOS" \
  -configuration Release \
  -derivedDataPath "$ROOT/.build/apple-ci" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  build

"$RELEASE_PYTHON" "$ROOT/tools/release/check_bundled_release.py" \
  "$ROOT/.build/apple-ci/Build/Products/Release/SparkPilot.app"

# Build watch silicon and simulator slices, then check the embedded companion.
xcodebuild \
  -workspace "$ROOT/apple/Spark.xcworkspace" \
  -scheme SparkWatch \
  -destination "generic/platform=watchOS Simulator" \
  -configuration Release \
  -derivedDataPath "$ROOT/.build/apple-ci-watch-simulator" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  build

python3 "$ROOT/tools/release/check_watch_bundle.py" \
  "$ROOT/.build/apple-ci/Build/Products/Release-iphoneos/Spark.app"
