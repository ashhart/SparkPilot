#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 --all | --diff <base> <head>" >&2
    exit 2
}

root="$(git rev-parse --show-toplevel)"
cd "$root"

configuration="$root/.swift-format"
swift_paths=(apple/Packages apple/SparkApp)

case "${1:-}" in
    --all)
        [[ "$#" -eq 1 ]] || usage
        swift format lint \
            --recursive \
            --strict \
            --configuration "$configuration" \
            -- "${swift_paths[@]}"
        ;;
    --diff)
        [[ "$#" -eq 3 ]] || usage
        base="$2"
        head="$3"

        if ! base_commit="$(git rev-parse --verify --quiet "${base}^{commit}")"; then
            echo "error: Swift format base is not a commit: $base" >&2
            exit 1
        fi
        if ! head_commit="$(git rev-parse --verify --quiet "${head}^{commit}")"; then
            echo "error: Swift format head is not a commit: $head" >&2
            exit 1
        fi
        if ! merge_base="$(git merge-base "$base_commit" "$head_commit")"; then
            echo "error: Swift format revisions have no merge base: $base $head" >&2
            exit 1
        fi

        changed_files="$(mktemp "${TMPDIR:-/tmp}/spark-swift-format.XXXXXX")"
        trap 'rm -f "$changed_files"' EXIT
        git diff \
            --no-ext-diff \
            --no-textconv \
            --find-renames \
            --name-only \
            --diff-filter=ACMR \
            -z \
            "$merge_base" \
            "$head_commit" \
            -- \
            ':(glob)apple/Packages/**/*.swift' \
            ':(glob)apple/SparkApp/**/*.swift' \
            >"$changed_files"

        files=()
        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] && files+=("$file")
        done <"$changed_files"

        if [[ "${#files[@]}" -eq 0 ]]; then
            echo "No added, copied, modified, or renamed Swift files to lint."
            exit 0
        fi

        printf 'Strict Swift format lint:'
        printf ' %q' "${files[@]}"
        printf '\n'
        swift format lint \
            --strict \
            --configuration "$configuration" \
            -- "${files[@]}"
        ;;
    *)
        usage
        ;;
esac
