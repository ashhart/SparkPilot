#!/usr/bin/env bash
# Sign recipes and publish the verified catalogue to the runtime package, app and website.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY="${SPARK_CATALOGUE_KEY:-$HOME/.config/spark-fabric/dev-release/catalogue-2026-b.ed25519}"
KEY_ID="${SPARK_CATALOGUE_KEY_ID:-catalogue-2026-b}"
WEBSITE="${SPARK_WEBSITE_DIR:-$ROOT/../website}"
PYTHON="${CONTRACT_PYTHON:-$ROOT/.build/contracts-venv312/bin/python3}"
[ -x "$PYTHON" ] || PYTHON=python3
TOOL="$ROOT/tools/catalogue/spark_catalogue.py"
OUTPUT="$ROOT/packaging/catalogue/bootstrap.lab.json"

[ -f "$KEY" ] || { echo "catalogue key not found: $KEY" >&2; exit 1; }

recipes=("$@")
if [ "${#recipes[@]}" -eq 0 ]; then
  for file in "$ROOT"/recipes/*.json; do
    case "$(basename "$file")" in
      *.service.json) continue ;;
    esac
    recipes+=("$file")
  done
fi
[ "${#recipes[@]}" -gt 0 ] || { echo "no model recipes under recipes/" >&2; exit 1; }

"$PYTHON" "$TOOL" release-check "${recipes[@]}"

echo "==> signing ${#recipes[@]} recipe(s) with $KEY_ID"
"$PYTHON" "$TOOL" sign --key "$KEY" --key-id "$KEY_ID" "${recipes[@]}"

echo "==> assembling $OUTPUT"
"$PYTHON" "$TOOL" assemble --key "$KEY" --key-id "$KEY_ID" --output "$OUTPUT" "${recipes[@]}"

echo "==> verifying against packaging/trust/catalogue-root.pub"
"$PYTHON" "$TOOL" verify --root "$ROOT/packaging/trust/catalogue-root.pub" --key-id "$KEY_ID" "$OUTPUT"
"$PYTHON" "$TOOL" release-check --catalogue "$OUTPUT"

cp "$OUTPUT" "$ROOT/apple/SparkApp/Shared/Resources/model-presets.json"
echo "==> app presets updated"

if [ -d "$WEBSITE/public" ]; then
  mkdir -p "$WEBSITE/public/models/v2"
  cp "$OUTPUT" "$WEBSITE/public/models/v2/catalogue.json"
  echo "==> website copy updated: $WEBSITE/public/models/v2/catalogue.json (deploy the site to publish)"
else
  echo "==> website not found at $WEBSITE; set SPARK_WEBSITE_DIR to publish there" >&2
fi

digest="$(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
count="$("$PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["recipes"]))' "$OUTPUT")"
echo "==> catalogue: $count recipe(s), SHA-256 $digest"
