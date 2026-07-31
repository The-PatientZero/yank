#!/usr/bin/env bash
set -euo pipefail

readonly ASC_API_BASE="https://api.appstoreconnect.apple.com"
readonly ASC_TOKEN_LIFETIME_SECONDS=300
readonly DEFAULT_PROCESSING_TIMEOUT_SECONDS=3600
readonly DEFAULT_POLL_INTERVAL_SECONDS=30
WORK_DIRECTORY=""

usage() {
    cat >&2 <<'EOF'
usage:
  app_store_connect.sh validate-token
  app_store_connect.sh next-build <app-id> <marketing-version>
  app_store_connect.sh wait-build <app-id> <marketing-version> <build-number> [timeout-seconds] [poll-seconds]
  app_store_connect.sh assign-build <group-id> <build-id>
  app_store_connect.sh verify-assignment <group-id> <build-id>

test-only parsers:
  app_store_connect.sh next-build-from-json <builds-response.json>
  app_store_connect.sh build-state-from-json <prerelease-response.json> <build-number>
  app_store_connect.sh relationship-has-build-from-json <relationship-response.json> <build-id>

Live commands require ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID.
EOF
    exit 64
}

fail() {
    echo "App Store Connect: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIRECTORY" && -d "$WORK_DIRECTORY" ]]; then
        rm -rf "$WORK_DIRECTORY"
    fi
}

ensure_work_directory() {
    if [[ -z "$WORK_DIRECTORY" ]]; then
        WORK_DIRECTORY="$(mktemp -d)"
        trap cleanup EXIT
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

validate_identifier() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[A-Za-z0-9-]+$ ]] || fail "invalid ${name}"
}

validate_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail "invalid marketing version"
}

validate_build_number() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "invalid build number"
}

require_authentication() {
    : "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
    : "${ASC_KEY_ID:?set ASC_KEY_ID}"
    : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
    [[ -f "$ASC_KEY_PATH" ]] || fail "API key file does not exist"
    validate_identifier "key ID" "$ASC_KEY_ID"
    validate_identifier "issuer ID" "$ASC_ISSUER_ID"
}

generate_token() {
    require_command ruby
    ASC_TOKEN_LIFETIME="$ASC_TOKEN_LIFETIME_SECONDS" ruby <<'RUBY'
require "base64"
require "json"
require "openssl"

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

key_path = ENV.fetch("ASC_KEY_PATH")
key_id = ENV.fetch("ASC_KEY_ID")
issuer_id = ENV.fetch("ASC_ISSUER_ID")
lifetime = Integer(ENV.fetch("ASC_TOKEN_LIFETIME"))
now = Time.now.to_i

header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
payload = base64url(
  JSON.generate(
    iss: issuer_id,
    iat: now,
    exp: now + lifetime,
    aud: "appstoreconnect-v1"
  )
)
signing_input = "#{header}.#{payload}"
key = OpenSSL::PKey.read(File.binread(key_path))
der_signature = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
sequence = OpenSSL::ASN1.decode(der_signature)
raw_signature = sequence.value.map { |integer|
  value = integer.value.to_i.to_s(16)
  value = "0#{value}" if value.length.odd?
  [value].pack("H*").rjust(32, "\0")
}.join
abort "unexpected ES256 signature width" unless raw_signature.bytesize == 64

print "#{signing_input}.#{base64url(raw_signature)}"
RUBY
}

validate_token() {
    local token
    require_authentication
    token="$(generate_token)"
    ASC_GENERATED_TOKEN="$token" ruby <<'RUBY'
require "base64"
require "openssl"

parts = ENV.fetch("ASC_GENERATED_TOKEN").split(".")
abort "JWT does not have three segments" unless parts.length == 3

def base64url_decode(value)
  padding = "=" * ((4 - value.length % 4) % 4)
  Base64.urlsafe_decode64(value + padding)
end

raw_signature = base64url_decode(parts[2])
abort "unexpected ES256 signature width" unless raw_signature.bytesize == 64
r = OpenSSL::BN.new(raw_signature.byteslice(0, 32), 2)
s = OpenSSL::BN.new(raw_signature.byteslice(32, 32), 2)
der_signature = OpenSSL::ASN1::Sequence([
  OpenSSL::ASN1::Integer(r),
  OpenSSL::ASN1::Integer(s)
]).to_der
key = OpenSSL::PKey.read(File.binread(ENV.fetch("ASC_KEY_PATH")))
digest = OpenSSL::Digest::SHA256.digest("#{parts[0]}.#{parts[1]}")
abort "JWT signature verification failed" unless key.dsa_verify_asn1(digest, der_signature)
RUBY
    echo "Token signing validated."
}

api_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"
    local token

    [[ "$url" == "${ASC_API_BASE}/v1/"* ]] || fail "refusing non-App-Store-Connect URL"
    token="$(generate_token)"

    if [[ -n "$body" ]]; then
        curl \
            --fail-with-body \
            --silent \
            --show-error \
            --retry 3 \
            --retry-all-errors \
            --retry-max-time 60 \
            --request "$method" \
            --header "Authorization: Bearer ${token}" \
            --header "Content-Type: application/json" \
            --data "$body" \
            "$url"
    else
        curl \
            --fail-with-body \
            --silent \
            --show-error \
            --retry 3 \
            --retry-all-errors \
            --retry-max-time 60 \
            --request "$method" \
            --header "Authorization: Bearer ${token}" \
            "$url"
    fi
}

fetch_all() {
    local url="$1"
    local combined="[]"
    local page
    local next

    while [[ -n "$url" ]]; do
        page="$(api_request GET "$url")"
        jq -e '.data | type == "array"' >/dev/null <<<"$page" \
            || fail "malformed paginated response"
        combined="$(
            jq -cn \
                --argjson current "$combined" \
                --argjson page "$(jq '.data' <<<"$page")" \
                '$current + $page'
        )"
        next="$(jq -er '.links.next // ""' <<<"$page")" \
            || fail "malformed pagination links"
        if [[ -n "$next" && "$next" != "${ASC_API_BASE}/v1/"* ]]; then
            fail "refusing pagination URL outside App Store Connect"
        fi
        url="$next"
    done

    jq -cn --argjson data "$combined" '{data: $data}'
}

next_build_from_json() {
    local json_file="$1"
    [[ -f "$json_file" ]] || fail "build response does not exist"

    jq -e '
        (.data | type == "array")
        and all(
            .data[];
            .type == "builds"
            and (.id | type == "string" and length > 0)
            and (.attributes.version | type == "string")
            and (.attributes.version | test("^[0-9]+$"))
        )
        and (
            [.data[].attributes.version]
            | group_by(.)
            | all(length == 1)
        )
    ' "$json_file" >/dev/null || fail "malformed, duplicate, or non-numeric build data"

    jq -er '[.data[].attributes.version | tonumber] | (max // 0) + 1' "$json_file"
}

build_state_from_json() {
    local json_file="$1"
    local build_number="$2"
    validate_build_number "$build_number"
    [[ -f "$json_file" ]] || fail "prerelease response does not exist"

    jq -e '
        (.data | type == "array")
        and ((.included // []) | type == "array")
        and all(
            (.included // [])[];
            .type != "builds"
            or (
                (.id | type == "string" and length > 0)
                and (.attributes.version | type == "string")
                and (
                    .attributes.processingState
                    | IN("PROCESSING", "FAILED", "INVALID", "VALID")
                )
            )
        )
    ' "$json_file" >/dev/null || fail "malformed prerelease response"

    local matching
    matching="$(
        jq -c \
            --arg build "$build_number" \
            '[
                (.included // [])[]
                | select(
                    .type == "builds"
                    and .attributes.version == $build
                    and (.id | type == "string" and length > 0)
                    and (
                        .attributes.processingState
                        | IN("PROCESSING", "FAILED", "INVALID", "VALID")
                    )
                )
            ]' \
            "$json_file"
    )"

    local count
    count="$(jq -r 'length' <<<"$matching")"
    [[ "$count" -le 1 ]] || fail "multiple builds matched the requested build number"
    if [[ "$count" -eq 0 ]]; then
        echo "MISSING"
        return
    fi

    jq -r '.[0] | "\(.id) \(.attributes.processingState)"' <<<"$matching"
}

relationship_has_build_from_json() {
    local json_file="$1"
    local build_id="$2"
    validate_identifier "build ID" "$build_id"
    [[ -f "$json_file" ]] || fail "relationship response does not exist"

    jq -e '
        (.data | type == "array")
        and all(
            .data[];
            .type == "builds"
            and (.id | type == "string" and length > 0)
        )
    ' "$json_file" >/dev/null || fail "malformed build relationship response"

    jq -e --arg build "$build_id" 'any(.data[]; .id == $build)' "$json_file" >/dev/null
}

find_prerelease_version() {
    local app_id="$1"
    local marketing_version="$2"
    local response
    local count

    response="$(
        api_request GET \
            "${ASC_API_BASE}/v1/preReleaseVersions?filter%5Bapp%5D=${app_id}&filter%5Bplatform%5D=IOS&filter%5Bversion%5D=${marketing_version}&limit=2"
    )"
    jq -e '
        (.data | type == "array")
        and all(
            .data[];
            .type == "preReleaseVersions"
            and (.id | type == "string" and length > 0)
            and .attributes.platform == "IOS"
        )
    ' >/dev/null <<<"$response" || fail "malformed prerelease-version response"
    count="$(jq -r '.data | length' <<<"$response")"
    [[ "$count" -le 1 ]] || fail "multiple iOS prerelease versions matched"
    [[ "$count" -eq 1 ]] || return 2
    jq -r '.data[0].id' <<<"$response"
}

next_build() {
    local app_id="$1"
    local marketing_version="$2"
    local prerelease_id
    local builds_file

    validate_identifier "app ID" "$app_id"
    validate_version "$marketing_version"
    require_authentication

    if prerelease_id="$(find_prerelease_version "$app_id" "$marketing_version")"; then
        :
    else
        local status="$?"
        [[ "$status" -eq 2 ]] || fail "unable to query prerelease version"
        echo "1"
        return
    fi

    ensure_work_directory
    builds_file="$WORK_DIRECTORY/builds.json"
    fetch_all \
        "${ASC_API_BASE}/v1/preReleaseVersions/${prerelease_id}/builds?fields%5Bbuilds%5D=version&limit=200" \
        >"$builds_file"
    next_build_from_json "$builds_file"
}

wait_build() {
    local app_id="$1"
    local marketing_version="$2"
    local build_number="$3"
    local timeout_seconds="${4:-$DEFAULT_PROCESSING_TIMEOUT_SECONDS}"
    local poll_seconds="${5:-$DEFAULT_POLL_INTERVAL_SECONDS}"
    local started_at="$SECONDS"
    local response_file
    local state
    local build_id

    validate_identifier "app ID" "$app_id"
    validate_version "$marketing_version"
    validate_build_number "$build_number"
    [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || fail "invalid processing timeout"
    [[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || fail "invalid poll interval"
    require_authentication

    ensure_work_directory
    response_file="$WORK_DIRECTORY/prerelease.json"

    while (( SECONDS - started_at < timeout_seconds )); do
        api_request GET \
            "${ASC_API_BASE}/v1/preReleaseVersions?filter%5Bapp%5D=${app_id}&filter%5Bplatform%5D=IOS&filter%5Bversion%5D=${marketing_version}&filter%5Bbuilds.version%5D=${build_number}&include=builds&limit=2&limit%5Bbuilds%5D=50" \
            >"$response_file"
        state="$(build_state_from_json "$response_file" "$build_number")"
        case "$state" in
            MISSING)
                ;;
            *" VALID")
                build_id="${state%% *}"
                echo "$build_id"
                return
                ;;
            *" FAILED"|*" INVALID")
                fail "build ${build_number} processing ended in ${state#* }"
                ;;
            *" PROCESSING")
                ;;
            *)
                fail "unexpected processing state"
                ;;
        esac
        sleep "$poll_seconds"
    done

    fail "build ${build_number} did not finish processing within ${timeout_seconds}s"
}

assign_build() {
    local group_id="$1"
    local build_id="$2"
    local body

    validate_identifier "group ID" "$group_id"
    validate_identifier "build ID" "$build_id"
    require_authentication
    if assignment_exists "$group_id" "$build_id"; then
        return
    fi

    body="$(jq -cn --arg id "$build_id" '{data: [{type: "builds", id: $id}]}')"
    api_request POST \
        "${ASC_API_BASE}/v1/betaGroups/${group_id}/relationships/builds" \
        "$body" >/dev/null
}

assignment_exists() {
    local group_id="$1"
    local build_id="$2"
    local response_file

    ensure_work_directory
    response_file="$WORK_DIRECTORY/group-builds.json"
    fetch_all \
        "${ASC_API_BASE}/v1/betaGroups/${group_id}/relationships/builds?limit=200" \
        >"$response_file"
    relationship_has_build_from_json "$response_file" "$build_id"
}

verify_assignment() {
    local group_id="$1"
    local build_id="$2"

    validate_identifier "group ID" "$group_id"
    validate_identifier "build ID" "$build_id"
    require_authentication
    assignment_exists "$group_id" "$build_id" \
        || fail "group does not contain build ${build_id}"
}

require_command jq
command="${1:-}"
case "$command" in
    validate-token)
        [[ "$#" -eq 1 ]] || usage
        validate_token
        ;;
    next-build)
        [[ "$#" -eq 3 ]] || usage
        next_build "$2" "$3"
        ;;
    wait-build)
        [[ "$#" -ge 4 && "$#" -le 6 ]] || usage
        wait_build "$2" "$3" "$4" "${5:-}" "${6:-}"
        ;;
    assign-build)
        [[ "$#" -eq 3 ]] || usage
        assign_build "$2" "$3"
        ;;
    verify-assignment)
        [[ "$#" -eq 3 ]] || usage
        verify_assignment "$2" "$3"
        ;;
    next-build-from-json)
        [[ "$#" -eq 2 ]] || usage
        next_build_from_json "$2"
        ;;
    build-state-from-json)
        [[ "$#" -eq 3 ]] || usage
        build_state_from_json "$2" "$3"
        ;;
    relationship-has-build-from-json)
        [[ "$#" -eq 3 ]] || usage
        relationship_has_build_from_json "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
