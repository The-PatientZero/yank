#!/usr/bin/env bash
set -euo pipefail

readonly XCODEGEN_VERSION="2.45.4"
readonly XCODEGEN_TARBALL_SHA256="90705e5c410a980f7d98f75462bba2120de7c94b721cc06fd3f7e52a52a1aeed"

WORK_ROOT="${RUNNER_TEMP:-/tmp}/xcodegen-${XCODEGEN_VERSION}"
ARCHIVE="$WORK_ROOT/xcodegen.tar.gz"
SOURCE="$WORK_ROOT/source"
PREFIX="${WORK_ROOT}/prefix"

rm -rf "$WORK_ROOT"
mkdir -p "$SOURCE"

curl -fsSL --retry 3 \
  "https://github.com/yonaskolb/XcodeGen/archive/refs/tags/${XCODEGEN_VERSION}.tar.gz" \
  -o "$ARCHIVE"
echo "${XCODEGEN_TARBALL_SHA256}  ${ARCHIVE}" | shasum -a 256 -c - >&2
tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
(cd "$SOURCE" && make install PREFIX="$PREFIX") >&2
"$PREFIX/bin/xcodegen" --version | grep -q "Version: ${XCODEGEN_VERSION}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$PREFIX/bin" >> "$GITHUB_PATH"
else
  echo "$PREFIX/bin/xcodegen"
fi
