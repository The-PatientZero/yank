#!/usr/bin/env bash
set -euo pipefail

readonly HOST_BUNDLE_ID="com.thepatientzero.yank"
readonly KEYBOARD_BUNDLE_ID="com.thepatientzero.yank.keyboard"
readonly SHARE_BUNDLE_ID="com.thepatientzero.yank.share"
readonly APP_GROUP_ID="group.com.thepatientzero.yank"
readonly ICLOUD_CONTAINER_ID="iCloud.com.thepatientzero.yank"

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 <archive.xcarchive> <marketing-version> <build-number> <team-id>" >&2
    exit 64
fi

ARCHIVE_PATH="$1"
EXPECTED_VERSION="$2"
EXPECTED_BUILD="$3"
EXPECTED_TEAM_ID="$4"

fail() {
    echo "Archive validation: $*" >&2
    exit 1
}

[[ -d "$ARCHIVE_PATH" ]] || fail "archive does not exist"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail "invalid marketing version"
[[ "$EXPECTED_BUILD" =~ ^[0-9]+$ ]] || fail "invalid build number"
[[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]+$ ]] || fail "invalid team ID"

HOST_APP="$(
    find "$ARCHIVE_PATH/Products/Applications" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name '*.app' \
        -print
)"
[[ -n "$HOST_APP" && "$(wc -l <<<"$HOST_APP" | tr -d ' ')" -eq 1 ]] \
    || fail "expected exactly one archived iOS app"

PLUGINS_PATH="$HOST_APP/PlugIns"
[[ -d "$PLUGINS_PATH" ]] || fail "archive does not contain PlugIns"
shopt -s nullglob
EXTENSIONS=("$PLUGINS_PATH"/*.appex)
shopt -u nullglob
[[ "${#EXTENSIONS[@]}" -eq 2 ]] || fail "expected exactly two embedded extensions"

TEMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

assert_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(plist_value "$plist" "$key")" || fail "missing ${key} in ${plist}"
    [[ "$actual" == "$expected" ]] \
        || fail "${key} mismatch in ${plist}: expected ${expected}, got ${actual}"
}

assert_plist_array_contains() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null \
        | grep -Fxq "    ${expected}" \
        || fail "${key} in ${plist} does not contain ${expected}"
}

bundle_identifier() {
    plist_value "$1/Info.plist" CFBundleIdentifier
}

bundle_for_identifier() {
    local expected="$1"
    local bundle
    for bundle in "$HOST_APP" "${EXTENSIONS[@]}"; do
        if [[ "$(bundle_identifier "$bundle")" == "$expected" ]]; then
            echo "$bundle"
            return
        fi
    done
    fail "missing bundle ${expected}"
}

HOST_BUNDLE="$(bundle_for_identifier "$HOST_BUNDLE_ID")"
KEYBOARD_BUNDLE="$(bundle_for_identifier "$KEYBOARD_BUNDLE_ID")"
SHARE_BUNDLE="$(bundle_for_identifier "$SHARE_BUNDLE_ID")"

validate_profile() {
    local bundle="$1"
    local bundle_id="$2"
    local label="$3"
    local profile="$bundle/embedded.mobileprovision"
    local decoded="$TEMP_DIRECTORY/${label}-profile.plist"

    [[ -f "$profile" ]] || fail "${label} has no embedded provisioning profile"
    security cms -D -i "$profile" >"$decoded" \
        || fail "${label} provisioning profile is unreadable"
    plutil -lint "$decoded" >/dev/null || fail "${label} provisioning profile is invalid"
    assert_plist_array_contains "$decoded" TeamIdentifier "$EXPECTED_TEAM_ID"
    assert_plist_value \
        "$decoded" \
        "Entitlements:application-identifier" \
        "${EXPECTED_TEAM_ID}.${bundle_id}"
    assert_plist_value "$decoded" "Entitlements:get-task-allow" "false"
    if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$decoded" >/dev/null 2>&1; then
        fail "${label} uses a device provisioning profile"
    fi
    if /usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$decoded" >/dev/null 2>&1; then
        fail "${label} uses an enterprise provisioning profile"
    fi
}

extract_entitlements() {
    local bundle="$1"
    local output="$2"
    codesign -d --entitlements :- "$bundle" >"$output" 2>/dev/null \
        || fail "cannot read signed entitlements for ${bundle}"
    plutil -lint "$output" >/dev/null || fail "invalid signed entitlements for ${bundle}"
}

validate_bundle() {
    local bundle="$1"
    local bundle_id="$2"
    local label="$3"
    local info="$bundle/Info.plist"
    local executable
    local signature_details="$TEMP_DIRECTORY/${label}-signature.txt"

    [[ -f "$info" ]] || fail "${label} has no Info.plist"
    assert_plist_value "$info" CFBundleIdentifier "$bundle_id"
    assert_plist_value "$info" CFBundleShortVersionString "$EXPECTED_VERSION"
    assert_plist_value "$info" CFBundleVersion "$EXPECTED_BUILD"
    [[ -f "$bundle/PrivacyInfo.xcprivacy" ]] || fail "${label} has no privacy manifest"
    plutil -lint "$bundle/PrivacyInfo.xcprivacy" >/dev/null \
        || fail "${label} privacy manifest is invalid"

    codesign --verify --strict --verbose=2 "$bundle" \
        || fail "${label} signature verification failed"
    codesign -dv --verbose=4 "$bundle" 2>"$signature_details" \
        || fail "${label} signature metadata is unreadable"
    grep -Eq '^Authority=(Apple Distribution|iPhone Distribution):' "$signature_details" \
        || fail "${label} is not distribution signed"
    grep -Fxq "TeamIdentifier=${EXPECTED_TEAM_ID}" "$signature_details" \
        || fail "${label} signature team mismatch"

    executable="$(plist_value "$info" CFBundleExecutable)" \
        || fail "${label} has no executable name"
    [[ -f "$bundle/$executable" ]] || fail "${label} executable is missing"
    lipo -info "$bundle/$executable" | grep -Eq 'architecture: arm64|are: arm64([[:space:]]|$)' \
        || fail "${label} executable is not arm64"

    validate_profile "$bundle" "$bundle_id" "$label"
}

validate_bundle "$HOST_BUNDLE" "$HOST_BUNDLE_ID" host
validate_bundle "$KEYBOARD_BUNDLE" "$KEYBOARD_BUNDLE_ID" keyboard
validate_bundle "$SHARE_BUNDLE" "$SHARE_BUNDLE_ID" share
codesign --verify --deep --strict --verbose=2 "$HOST_BUNDLE" \
    || fail "deep host signature verification failed"

HOST_ENTITLEMENTS="$TEMP_DIRECTORY/host-entitlements.plist"
KEYBOARD_ENTITLEMENTS="$TEMP_DIRECTORY/keyboard-entitlements.plist"
SHARE_ENTITLEMENTS="$TEMP_DIRECTORY/share-entitlements.plist"
extract_entitlements "$HOST_BUNDLE" "$HOST_ENTITLEMENTS"
extract_entitlements "$KEYBOARD_BUNDLE" "$KEYBOARD_ENTITLEMENTS"
extract_entitlements "$SHARE_BUNDLE" "$SHARE_ENTITLEMENTS"

assert_plist_value "$HOST_ENTITLEMENTS" aps-environment production
assert_plist_value \
    "$HOST_ENTITLEMENTS" \
    com.apple.developer.icloud-container-environment \
    Production
assert_plist_array_contains \
    "$HOST_ENTITLEMENTS" \
    com.apple.security.application-groups \
    "$APP_GROUP_ID"
assert_plist_array_contains \
    "$HOST_ENTITLEMENTS" \
    com.apple.developer.icloud-container-identifiers \
    "$ICLOUD_CONTAINER_ID"
assert_plist_array_contains \
    "$KEYBOARD_ENTITLEMENTS" \
    com.apple.security.application-groups \
    "$APP_GROUP_ID"
assert_plist_array_contains \
    "$SHARE_ENTITLEMENTS" \
    com.apple.security.application-groups \
    "$APP_GROUP_ID"

for extension_entitlements in "$KEYBOARD_ENTITLEMENTS" "$SHARE_ENTITLEMENTS"; do
    if /usr/libexec/PlistBuddy -c "Print :aps-environment" "$extension_entitlements" >/dev/null 2>&1; then
        fail "extension unexpectedly has APNs entitlement"
    fi
    if /usr/libexec/PlistBuddy \
        -c "Print :com.apple.developer.icloud-container-identifiers" \
        "$extension_entitlements" >/dev/null 2>&1; then
        fail "extension unexpectedly has CloudKit entitlement"
    fi
done

if grep -R -I -q "YOUR_TEAM_ID" "$ARCHIVE_PATH/Info.plist" "$HOST_APP"; then
    fail "archive contains placeholder team ID"
fi

echo "Archive validation passed: ${EXPECTED_VERSION} (${EXPECTED_BUILD})"
