#!/bin/bash
# Official release pipeline for Yank: a signed, notarized, stapled, UNIVERSAL DMG.
#
# This is the only path that produces a distributable build. Self-builds don't use it —
# they just open Yank.xcodeproj in Xcode and run (unsigned, local-only, no sync).
#
# Why xcodebuild (not raw swiftc): -exportArchive embeds a Developer ID provisioning
# profile, which AUTHORIZES the restricted iCloud entitlement so CloudKit works at
# runtime. It also builds from the single project source of truth (sources, assets,
# Info.plist, entitlements), so nothing drifts.
#
# Requires a .env (never committed) defining:
#   APP_NAME        e.g. Yank            (product + .app/.dmg name)
#   TEAM_ID         Apple Developer Team ID used for app signing/export
#   SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAM_ID>)"   (for signing the DMG)
#   NOTARY_PROFILE  notarytool keychain profile name (see `xcrun notarytool store-credentials`)
# The app itself is signed by Xcode during export from a temporary options plist.

set -eo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "Loading environment..."
# Local releases configure via .env; CI passes the same variables directly.
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

: "${APP_NAME:?set APP_NAME in .env}"
: "${TEAM_ID:?set TEAM_ID in .env (Apple Developer Team ID)}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY in .env (Developer ID Application identity)}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE in .env (xcrun notarytool keychain profile)}"

# -allowProvisioningUpdates needs App Store Connect auth on CI runners (no logged-in
# Xcode account). Locally these stay unset and Xcode's account is used.
ASC_AUTH_ARGS=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    ASC_AUTH_ARGS=(
        -authenticationKeyPath "${ASC_KEY_PATH}"
        -authenticationKeyID "${ASC_KEY_ID:?set ASC_KEY_ID with ASC_KEY_PATH}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?set ASC_ISSUER_ID with ASC_KEY_PATH}"
    )
fi

echo "Generating Xcode project from project.yml..."
command -v xcodegen >/dev/null 2>&1 || {
    echo 'xcodegen not found — run: XCODEGEN_BIN="$(scripts/install_xcodegen.sh)"; export PATH="$(dirname "$XCODEGEN_BIN"):$PATH"'
    exit 1
}
xcodegen generate

SCHEME="Yank"
CONFIG="Release"
BUILD_DIR="${REPO_ROOT}/build"
RELEASE_BUILD_DIR="${BUILD_DIR}/release"
DIST_DIR="${BUILD_DIR}/dist"
ARCHIVE_PATH="${RELEASE_BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${RELEASE_BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
# DMG staging lives outside the repo (hygiene + defense-in-depth): it holds an
# `Applications -> /Applications` symlink, and a build artifact that symlinks the entire
# /Applications tree into the working directory invites any tool that walks the repo to
# wander into it. This once ballooned `swift test` to tens of GB, back when YankCore used
# `path: "."` and llbuild followed the symlink; that root cause is fixed (YankCore now lives
# in Sources/YankCore), but keeping the artifact out-of-tree is the right call regardless.
# A temp dir holds the staging; the trap removes it on exit.
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-dmg.XXXXXX")"
trap 'rm -rf "${DMG_STAGE}"' EXIT
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
EXPORT_OPTIONS_TEMPLATE="${SCRIPT_DIR}/ExportOptions.plist"
EXPORT_OPTIONS_PLIST="${RELEASE_BUILD_DIR}/ExportOptions.plist"

echo "Cleaning release build output..."
rm -rf "${RELEASE_BUILD_DIR}"
rm -f "${DMG_PATH}"
mkdir -p "${RELEASE_BUILD_DIR}" "${DIST_DIR}"

echo "Preparing export options..."
cp "${EXPORT_OPTIONS_TEMPLATE}" "${EXPORT_OPTIONS_PLIST}"
/usr/libexec/PlistBuddy -c "Set :teamID ${TEAM_ID}" "${EXPORT_OPTIONS_PLIST}"

# Automatic signing cannot export Developer ID on CI: xcodebuild insists on cloud-creating
# the profile, which Apple restricts regardless of API-key role. When a profile name is
# supplied, switch the export to manual signing against that (pre-installed) profile.
# Locally (Xcode logged in) leave it unset and automatic signing works as before.
if [ -n "${PROVISIONING_PROFILE_NAME:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :signingStyle manual" "${EXPORT_OPTIONS_PLIST}"
    /usr/libexec/PlistBuddy -c "Add :signingCertificate string Developer ID Application" "${EXPORT_OPTIONS_PLIST}"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "${EXPORT_OPTIONS_PLIST}"
    /usr/libexec/PlistBuddy \
        -c "Add :provisioningProfiles:com.thepatientzero.yank string ${PROVISIONING_PROFILE_NAME}" \
        "${EXPORT_OPTIONS_PLIST}"
fi

# The archive must use the same installed Developer ID assets as the export. Leaving
# the project on automatic signing here makes a clean CI runner create a throwaway
# Apple Development certificate and team profile. Besides being unnecessary, those
# certificates accumulate until Apple's account quota blocks otherwise valid releases.
ARCHIVE_SIGNING_ARGS=(
    -allowProvisioningUpdates
    "${ASC_AUTH_ARGS[@]}"
)
EXPORT_AUTH_ARGS=(
    -allowProvisioningUpdates
    "${ASC_AUTH_ARGS[@]}"
)
if [ -n "${PROVISIONING_PROFILE_NAME:-}" ]; then
    ARCHIVE_SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"
        PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_NAME}"
    )
    EXPORT_AUTH_ARGS=()
fi

echo "Archiving (universal arm64 + x86_64, hardened runtime, from the Yank scheme)..."
xcodebuild archive \
    -project Yank.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    "${ARCHIVE_SIGNING_ARGS[@]}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    ONLY_ACTIVE_ARCH=NO

echo "Exporting Developer ID app (embeds the provisioning profile that authorizes CloudKit)..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
    "${EXPORT_AUTH_ARGS[@]}"

echo "Verifying app signature + universality..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
lipo -info "${APP_PATH}/Contents/MacOS/${APP_NAME}"

echo "Staging DMG..."
mkdir -p "${DMG_STAGE}"
cp -R "${APP_PATH}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"

echo "Creating DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO \
    "${DMG_PATH}"

echo "Signing DMG (Developer ID)..."
SIGN_OK=false
for attempt in 1 2 3; do
    if codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"; then
        SIGN_OK=true
        break
    fi
    echo "DMG signing attempt ${attempt} failed (timestamp.apple.com unreachable?), retrying in 3s..."
    sleep 3
done
[ "${SIGN_OK}" = true ] || { echo "DMG signing failed after 3 attempts — check network to timestamp.apple.com"; exit 1; }

echo "Notarizing DMG (macOS 26 notary can be slow — this may take a while)..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "Stapling..."
xcrun stapler staple "${DMG_PATH}"

echo "Validating..."
xcrun stapler validate "${DMG_PATH}"
spctl -a -vvv -t install "${DMG_PATH}" || echo "(spctl note: review the assessment above)"

# The in-app updater consumes a ZIP of the bare app with a .sha256 sidecar — it
# ditto-extracts the ZIP, expects Yank.app at its root, and Gatekeeper-assesses it,
# so the app bundle is stapled before zipping to validate offline.
echo "Stapling the app bundle and packaging the updater ZIP..."
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-universal.zip"
xcrun stapler staple "${APP_PATH}"
ditto -ck --keepParent "${APP_PATH}" "${ZIP_PATH}"
(cd "${DIST_DIR}" && shasum -a 256 "$(basename "${ZIP_PATH}")" > "$(basename "${ZIP_PATH}").sha256")
(cd "${DIST_DIR}" && shasum -a 256 "$(basename "${DMG_PATH}")" > "$(basename "${DMG_PATH}").sha256")

echo ""
echo "DONE → ${DIST_DIR}"
echo "  ${APP_NAME}.dmg                      signed · notarized · stapled · universal (human download)"
echo "  ${APP_NAME}-${VERSION}-universal.zip stapled app for the in-app updater (+ .sha256 sidecars)"
