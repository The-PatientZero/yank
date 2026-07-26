# Yank - Release Overview

Releases are cut by pushing a version tag; GitHub Actions does the rest. Prefer
`v<version>` tags for public releases. The workflow also accepts bare semver tags
(`1.2.3`) and strips the optional `v` before comparing against `MARKETING_VERSION`.

```bash
# 1. Move CHANGELOG.md Unreleased notes into a dated version section.
# 2. Bump MARKETING_VERSION in project.yml (the workflow refuses a mismatched tag), commit.
# 3. Verify the release notes section (replace 1.2.3 with the release version):
bash scripts/extract_release_notes.sh v1.2.3
# 4. Tag and push the same version (preferred form):
git tag v1.2.3
git push origin v1.2.3
```

The `Release` workflow (`.github/workflows/release.yml`) then:

1. Builds, signs, and notarizes the universal DMG via `scripts/build_dmg.sh`, plus the
   stapled-app ZIP + `.sha256` sidecars the in-app updater consumes.
2. Publishes the GitHub release with all four assets and the matching `CHANGELOG.md` section.
3. Opens a PR to refresh `releases.json` — the updater's feed — and attempts
   auto-merge for that PR only.
4. Bumps the Homebrew cask in `The-PatientZero/homebrew-tap`.

`ci.yml` runs `swift test` and unsigned macOS/iOS builds on every push and PR.

## Required repository secrets

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate, exported as `.p12`, base64-encoded |
| `P12_PASSWORD` | Password of that `.p12` export |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_SIGN_IDENTITY` | e.g. `Developer ID Application: <Name> (<TEAM_ID>)` |
| `ASC_KEY_B64` | App Store Connect API key (`.p8`), base64-encoded — used for notarization and CI provisioning |
| `ASC_KEY_ID` | Key ID of that API key |
| `ASC_ISSUER_ID` | Issuer ID from App Store Connect → Integrations |
| `MAC_PROVISIONING_PROFILE_B64` | Developer ID provisioning profile (`.provisionprofile`), base64-encoded — created manually in the developer portal (cloud signing cannot create Developer ID profiles) |
| `TAP_PUSH_TOKEN` | Fine-grained PAT with contents read/write on `homebrew-tap` only |

Local releases still work without CI: put `APP_NAME`, `TEAM_ID`, `SIGN_IDENTITY`, and
`NOTARY_PROFILE` in `.env` and run `./scripts/build_dmg.sh`, extract notes with
`bash scripts/extract_release_notes.sh <tag>`, then create the GitHub release with
`--notes-file`, refresh `releases.json`, and run `./scripts/update_homebrew_cask.sh <version>`
by hand.

iOS App Store submission stays manual (Xcode → Archive → App Store Connect). Before promoting
an iOS release candidate, copy `docs/IOS_RELEASE_EVIDENCE_TEMPLATE.md` to a versioned evidence
file and complete the device matrix in `docs/iOS_DEVICE_QA.md`; simulator CI cannot validate
App Group access on physical devices, keyboard insertion, CloudKit push delivery, iCloud account state, or file
protection. The app is free and open source on both platforms — no purchase, StoreKit IAP, or
storefront setup.

Published tags and binaries are immutable. Never replace or force-move a published tag. Correct a
released defect with a newer patch version, and do not use rollback steps that discard or rewrite
local history, tombstones, blobs, or CloudKit state. For the narrowly scoped historical-record
recovery command, follow [`CLOUDKIT_BACKFILL.md`](CLOUDKIT_BACKFILL.md) and require its zero exit
status plus converged marker before recording success.
