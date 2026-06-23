#!/bin/bash
# Updates the Homebrew cask in the sibling homebrew-tap repo after a DMG release.
#
# Run AFTER `build_dmg.sh` and after the DMG is uploaded as `Yank.dmg` to the
# `v<version>` GitHub release on The-PatientZero/yank — the cask URL is derived
# from that tag, so the asset must exist before the cask is pushed.
#
# Usage:
#   ./scripts/update_homebrew_cask.sh <version> [dmg-path]
#   e.g. ./scripts/update_homebrew_cask.sh 1.0.0
#
# Defaults: dmg-path = build/dist/Yank.dmg, tap = ../homebrew-tap (override with TAP_DIR).

set -eo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

VERSION="${1:?usage: update_homebrew_cask.sh <version> [dmg-path]}"
DMG_PATH="${2:-${REPO_ROOT}/build/dist/Yank.dmg}"
TAP_DIR="${TAP_DIR:-${REPO_ROOT}/../homebrew-tap}"
CASK_PATH="${TAP_DIR}/Casks/yank.rb"

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be semver (got: ${VERSION})"; exit 1; }
[[ -f "${DMG_PATH}" ]] || { echo "DMG not found: ${DMG_PATH} — run build_dmg.sh first"; exit 1; }
[[ -d "${TAP_DIR}/.git" ]] || { echo "Tap repo not found: ${TAP_DIR} — clone The-PatientZero/homebrew-tap next to this repo"; exit 1; }

mkdir -p "$(dirname -- "${CASK_PATH}")"
if [[ ! -f "${CASK_PATH}" ]]; then
    cat > "${CASK_PATH}" <<'CASK'
cask "yank" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/The-PatientZero/yank/releases/download/v#{version}/Yank.dmg",
      verified: "github.com/The-PatientZero/yank/"
  name "Yank"
  desc "Fast, private clipboard manager with iCloud sync"
  homepage "https://getyank.vercel.app/"

  livecheck do
    url "https://github.com/The-PatientZero/yank"
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Yank.app"

  uninstall quit: "com.thepatientzero.yank"

  zap trash: [
    "~/Library/Application Support/Yank",
    "~/Library/Caches/com.thepatientzero.yank",
    "~/Library/HTTPStorages/com.thepatientzero.yank",
    "~/Library/Preferences/com.thepatientzero.yank.plist",
  ]

  caveats <<~EOS
    Yank pastes via synthetic keystrokes, which requires macOS Accessibility access:
      System Settings → Privacy & Security → Accessibility → enable Yank
  EOS
end
CASK
fi

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"

echo "Updating ${CASK_PATH} → version ${VERSION}, sha256 ${SHA256}"
perl -pi -e "s/^(  version \").*(\")$/\${1}${VERSION}\${2}/" "${CASK_PATH}"
perl -pi -e "s/^(  sha256 \").*?(\").*$/\${1}${SHA256}\${2}/" "${CASK_PATH}"

grep -q "version \"${VERSION}\"" "${CASK_PATH}" || { echo "Failed to write version"; exit 1; }
grep -q "sha256 \"${SHA256}\"" "${CASK_PATH}" || { echo "Failed to write sha256"; exit 1; }

# `brew style` only resolves casks inside a registered tap, so check via the tap token
# when it's installed; the raw working-clone path is invisible to it.
if command -v brew >/dev/null 2>&1 && brew tap 2>/dev/null | grep -q "^the-patientzero/tap$"; then
    brew style --cask the-patientzero/tap/yank \
        || { echo "brew style failed — fix the cask before committing"; exit 1; }
else
    ruby -c "${CASK_PATH}" >/dev/null || { echo "Cask is not valid Ruby"; exit 1; }
    echo "Note: 'the-patientzero/tap' not tapped — ran a Ruby syntax check only."
fi

git -C "${TAP_DIR}" add Casks/yank.rb
git -C "${TAP_DIR}" commit -m "yank ${VERSION}"

echo "Done. Push the tap to publish:  git -C ${TAP_DIR} push"
