#!/usr/bin/env bash
set -euo pipefail

: "${XCODEGEN_VERSION:?XCODEGEN_VERSION is required}"
: "${XCODEGEN_TARBALL_SHA256:?XCODEGEN_TARBALL_SHA256 is required}"

WORK_ROOT="${RUNNER_TEMP:-/tmp}/xcodegen-${XCODEGEN_VERSION}"
ARCHIVE="$WORK_ROOT/xcodegen.tar.gz"
SOURCE="$WORK_ROOT/source"
PREFIX="${WORK_ROOT}/prefix"

rm -rf "$WORK_ROOT"
mkdir -p "$SOURCE"

curl -fsSL --retry 3 \
  "https://github.com/yonaskolb/XcodeGen/archive/refs/tags/${XCODEGEN_VERSION}.tar.gz" \
  -o "$ARCHIVE"
echo "${XCODEGEN_TARBALL_SHA256}  ${ARCHIVE}" | shasum -a 256 -c -
tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
(cd "$SOURCE" && make install PREFIX="$PREFIX")
"$PREFIX/bin/xcodegen" --version | grep -q "Version: ${XCODEGEN_VERSION}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$PREFIX/bin" >> "$GITHUB_PATH"
else
  echo "$PREFIX/bin"
fi
