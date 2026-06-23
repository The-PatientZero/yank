#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <tag> [CHANGELOG.md]" >&2
  exit 64
fi

TAG="$1"
VERSION="${TAG#v}"
CHANGELOG="${2:-CHANGELOG.md}"

if [ ! -f "$CHANGELOG" ]; then
  echo "Missing changelog: $CHANGELOG" >&2
  exit 1
fi

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT

if ! awk -v version="$VERSION" -v tag="$TAG" '
  /^##[[:space:]]+/ {
    if (in_section) {
      exit 0
    }

    header = $0
    sub(/^##[[:space:]]+/, "", header)
    candidate = header
    if (candidate ~ /^\[/) {
      sub(/^\[/, "", candidate)
      sub(/\].*$/, "", candidate)
    } else {
      sub(/[[:space:]].*$/, "", candidate)
    }

    if (candidate == version || candidate == tag) {
      found = 1
      in_section = 1
      next
    }
  }

  in_section {
    if (!seen_content && $0 ~ /^[[:space:]]*$/) {
      next
    }
    seen_content = 1
    print
  }

  END {
    if (!found) {
      exit 3
    }
  }
' "$CHANGELOG" > "$NOTES_FILE"; then
  echo "No changelog section found for $TAG in $CHANGELOG" >&2
  exit 1
fi

if ! grep -Eq '[^[:space:]]' "$NOTES_FILE"; then
  echo "Changelog section for $TAG is empty" >&2
  exit 1
fi

cat "$NOTES_FILE"
