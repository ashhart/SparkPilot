#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Every intent SparkPilotShortcuts registers. AppIntentsMetadataGateTests fails if the two drift.
expected='["AnalyseFileWithSparkIntent","AskSparkIntent","CheckSparkStatusIntent","DraftEmailWithSparkIntent","DraftReplyWithSparkIntent","GetSparkAnalysisIntent","LoadSparkModelIntent","RewriteWithSparkIntent","SummarizeWithSparkIntent","UnloadActiveModelIntent"]'

validate_metadata() {
    local metadata="$1"
    if [[ ! -f "$metadata" ]]; then
        echo "missing App Intents metadata: $metadata" >&2
        return 1
    fi

    jq -e --argjson expected "$expected" '
        ([.actions[].identifier] | sort) == ($expected | sort)
        and ([.autoShortcuts[].actionIdentifier] | sort) == ($expected | sort)
        and all(.autoShortcuts[]; (.phraseTemplates | length) > 0)
    ' "$metadata" >/dev/null || {
        echo "App Intent actions or shortcut phrases are incomplete: $metadata" >&2
        return 1
    }
}

if (( $# > 0 )); then
    for metadata in "$@"; do
        validate_metadata "$metadata"
    done
    exit 0
fi

derived_data="${SPARK_INTENTS_DERIVED_DATA:-$repo_root/.build/app-intents-metadata}"
project="$repo_root/apple/SparkApp/SparkApp.xcodeproj"

xcodebuild \
    -project "$project" \
    -scheme Spark \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

xcodebuild \
    -project "$project" \
    -scheme SparkMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

validate_metadata \
    "$derived_data/Build/Products/Debug-iphoneos/Spark.app/Metadata.appintents/extract.actionsdata"
validate_metadata \
    "$derived_data/Build/Products/Debug/SparkPilot.app/Contents/Resources/Metadata.appintents/extract.actionsdata"
