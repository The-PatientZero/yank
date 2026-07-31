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
Before publishing a signed macOS artifact, verify its effective entitlements select CloudKit
`Production` and APNs `production`; a signed Debug diagnostic build must select CloudKit
`Development` and APNs `development`.

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

## Internal TestFlight promotion

The `TestFlight` workflow is a manual, `main`-only release path. It reruns the
package, generated-project, macOS, and iOS simulator gates before its protected
job can read Apple credentials. It then selects the next build number from live
App Store Connect data, archives and validates all three iOS bundles, uploads an
internal-only build, waits for Apple processing, assigns the exact build to the
configured internal group, and verifies that relationship.

Configure a GitHub environment named `testflight`, restrict it to `main`, and
add a required reviewer when the repository plan supports that protection.
Store only the dedicated TestFlight key in this environment:

| Environment secret | Value |
|---|---|
| `TESTFLIGHT_ASC_KEY_B64` | Dedicated App Store Connect API `.p8`, base64-encoded |
| `TESTFLIGHT_ASC_KEY_ID` | Key ID for that dedicated key |
| `TESTFLIGHT_ASC_ISSUER_ID` | Team issuer ID from App Store Connect → Integrations |

Add these non-secret environment variables:

| Environment variable | Value |
|---|---|
| `TESTFLIGHT_APP_ID` | Opaque App Store Connect app resource ID, not the bundle ID |
| `TESTFLIGHT_INTERNAL_GROUP_ID` | Opaque ID of the intended internal beta group |

The workflow reuses the repository-level `APPLE_TEAM_ID` secret already used by
the macOS release workflow; do not duplicate that identifier into the
environment. The dedicated TestFlight key uses App Manager access. Do not
broaden it to Admin or reuse the existing Admin release key. App Store Connect
team keys apply across the team, so the dedicated GitHub environment is the
credential access boundary. Never reuse the Developer ID certificate or
notarization credentials for this workflow.

To promote:

1. Confirm `main` contains the intended release-candidate commit and that
   `MARKETING_VERSION` in `project.yml` is correct.
2. In GitHub, open Actions → TestFlight → Run workflow, keep the branch set to
   `main`, and approve the protected environment job when prompted.
3. Treat the workflow as successful only when its summary reports archive
   validation, Apple processing, and internal-group assignment as verified.
4. Run the physical-device smoke matrix from `docs/iOS_DEVICE_QA.md` against
   that exact TestFlight version/build and record it with
   `docs/IOS_RELEASE_EVIDENCE_TEMPLATE.md`.

An Xcode upload receipt is not processing proof, and processing is not internal
distribution proof. Simulator CI also cannot validate App Group access on
physical devices, keyboard insertion, CloudKit push delivery, iCloud account
state, file protection, or accessibility on the signed build. External
TestFlight, Beta App Review, and App Store submission remain manual, separately
authorized gates. The app is free and open source on both platforms — no
purchase, StoreKit IAP, or storefront setup.

If a run fails before upload, fix the cause and dispatch again; the serialized
workflow will select a fresh live build number. If upload succeeds, first locate
the exact version/build in App Store Connect before retrying. A processed build
can be assigned without re-uploading. Never delete or replace an uploaded build;
correct it with a newer build. To disable the pipeline, remove access to the
`testflight` environment. To remove persistent access, delete its GitHub secrets
and revoke the dedicated key in App Store Connect; either action alone is not a
complete credential revocation.

Published tags and binaries are immutable. Never replace or force-move a published tag. Correct a
released defect with a newer patch version, and do not use rollback steps that discard or rewrite
local history, tombstones, blobs, or CloudKit state. For the narrowly scoped historical-record
recovery command, follow [`CLOUDKIT_BACKFILL.md`](CLOUDKIT_BACKFILL.md) and require its zero exit
status plus converged marker before recording success.
