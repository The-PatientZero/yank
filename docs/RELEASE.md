# Yank - Release Overview

Releases are cut by pushing a version tag; GitHub Actions does the rest. Prefer
`v<version>` tags for public releases. The workflow also accepts bare semver tags
(`1.2.3`) and strips the optional `v` before comparing against `MARKETING_VERSION`.

```bash
# 1. Move CHANGELOG.md Unreleased notes into a dated version section.
# 2. Bump MARKETING_VERSION in project.yml (the workflow refuses a mismatched tag), commit.
# 3. If the release adds CloudKit record fields, promote the schema first (see below).
# 4. Verify the release notes section (replace 1.2.3 with the release version):
bash scripts/extract_release_notes.sh v1.2.3
# 5. Tag and push the same version (preferred form):
git tag v1.2.3
git push origin v1.2.3
# 6. Open the run in Actions → Release. Once "Verify release source" passes, the
#    "release" job waits for review: check the tag, the commit and the version, then approve it.
```

The release commit must already be on `main` before you tag it. If it is not, the
workflow stops at its first job and nothing is built. Approve exactly one run per
version. A run nobody approves expires after 30 days and leaves a tag with no release;
see [Protect the release environment](#protect-the-release-environment) for what to do
with it. To recover a failed run for an existing tag, use Actions → Release → Run
workflow with the branch set to `main` and the tag name; a dispatch from any other
branch is rejected.

## CloudKit schema

Debug builds use the CloudKit `Development` environment and Release builds use `Production`
(see the entitlement note below). CloudKit creates a record field in Development the first
time a build saves a record that carries it, but a Production container only knows the fields
that were deployed to it. A Release build that saves a record with a field Production lacks
fails every save of that record, and sync keeps retrying with a "could not save" status.

Before tagging any release that adds record fields, as a manual step (nothing in CI checks it):

1. Run a Debug build against Development and save a clip that populates every field the
   release adds. For the encrypted content field `encContent`, any saved live clip creates it;
   copying a tagged text clip and extracting text from an image exercises every value it holds.
2. In CloudKit Console, open the container, choose the Development environment, and confirm
   the new fields are listed under the `ClipboardItem` record type (`encContent` appears as
   an encrypted bytes field).
3. Deploy the Development schema to Production from CloudKit Console and confirm the new
   fields appear there before pushing the tag.

An existing field cannot be turned into an encrypted one, so new encrypted content always gets
a new field.

The device record is a separate step, because it is a new record type rather than a field on
`ClipboardItem`. Before tagging a release that includes it:

1. Run a Debug build against Development with iCloud sync on. It saves one `DeviceSyncFormat`
   record, named with the install's device ID, in the zone `YankDevicesZone`.
2. In CloudKit Console (Development), confirm the record type `DeviceSyncFormat` exists with
   its five fields: `encryptedFormat`, `encryptedOnlySince`, `sweepCompletedAt`, `olderOrigins`
   and `olderOriginSeen`. `encryptedFormat` appears with the first save. `encryptedOnlySince`
   and `sweepCompletedAt` appear once the rollout opens and the sweep finishes. `olderOrigins`
   and `olderOriginSeen` (a list of dates) appear only when a device record is saved that names
   an older origin, meaning clips from a device that has no device record. To reach those states
   without waiting days, launch the Debug build with the arguments in
   `Sources/YankCloudKitSync/DebugRolloutOverrides.swift`, for example
   `-yankRolloutSoakSeconds 30 -yankLegacyActivityWindowSeconds 30
   -yankRolloutEvaluationIntervalSeconds 10`. A field missing from Development will be
   missing from Production too, because the next step deploys what Development has.
3. Deploy the Development schema to Production and confirm `DeviceSyncFormat` appears there.
   Without it, device records fail to save, the encrypted-only rollout never opens, and clip
   sync is otherwise unaffected.

`ClipboardItem` gets no new CloudKit field for this: the extra payload keys live inside the bytes
of the encrypted `encContent` field. The zone `YankDevicesZone` is created by the app and needs
no deployment.

The `Release` workflow (`.github/workflows/release.yml`) then:

0. Checks, without any secret, that the tag is well formed, that its commit is already
   part of `main`, that it matches `MARKETING_VERSION` and that `CHANGELOG.md` has its
   section. A failure here costs no approval.
1. After a reviewer approves the run in the `release` environment, builds, signs, and notarizes the universal DMG via `scripts/build_dmg.sh`, plus the
   stapled-app ZIP + `.sha256` sidecars the in-app updater consumes.
2. Signs build provenance for the DMG and ZIP, then publishes the GitHub release with all four
   assets, the provenance bundle (`Yank-<version>.intoto.jsonl`), and the matching `CHANGELOG.md` section. Releases are immutable once published.
3. Opens a PR to refresh `releases.json` — the updater's feed — and attempts
   auto-merge for that PR only.
4. Opens a PR in `The-PatientZero/homebrew-tap` that bumps the Homebrew cask. The tap requires a
   review, so merge that PR by hand.

The macOS archive and export both use the preinstalled Developer ID certificate and
provisioning profile. Release CI must not create ephemeral Apple Development certificates;
they are unnecessary for Developer ID distribution and can exhaust Apple's certificate quota.

`ci.yml` runs `swift test` and unsigned macOS/iOS builds on every push and PR.
Before publishing a signed macOS artifact, verify its effective entitlements select CloudKit
`Production` and APNs `production`; a signed Debug diagnostic build must select CloudKit
`Development` and APNs `development`.

## Required environment secrets (`release`)

These secrets live in the `release` environment, not at repository level, so a job can
read them only after the environment's reviewer approves the run.

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate, exported as `.p12`, base64-encoded |
| `P12_PASSWORD` | Password of that `.p12` export |
| `APPLE_SIGN_IDENTITY` | e.g. `Developer ID Application: <Name> (<TEAM_ID>)` |
| `ASC_KEY_B64` | App Store Connect API key (`.p8`), base64-encoded — used for notarization and CI provisioning |
| `ASC_KEY_ID` | Key ID of that API key |
| `ASC_ISSUER_ID` | Issuer ID from App Store Connect → Integrations |
| `MAC_PROVISIONING_PROFILE_B64` | Developer ID provisioning profile (`.provisionprofile`), base64-encoded — created manually in the developer portal (cloud signing cannot create Developer ID profiles) |
| `TAP_PUSH_TOKEN` | Fine-grained PAT on `homebrew-tap` only, with contents and pull requests read/write |

`ASC_KEY_B64`, `ASC_KEY_ID` and `ASC_ISSUER_ID` are also read by the TestFlight
cloud-signing step, and an environment secret is invisible to a job in another
environment. Keep the same three values as `testflight` environment secrets too.
`APPLE_TEAM_ID` is an identifier, not a credential; it stays a repository secret used by
both workflows.

## Protect the release environment

The `Release` workflow checks the tag in a first job that has no secrets, and only then
starts the `release` job, which is bound to the protected `release` environment. The
workflow file alone cannot be the control, because a tag run uses the workflow file of the
tagged commit. What holds is:

- **Signing material:** once the secrets exist only in the `release` environment, a
  modified workflow that does not name the environment cannot read them, and one that
  does must pass the reviewer. The environment's allowed-refs rule matches the ref name,
  not where the tagged commit lives, so the reviewer is the check for a tag on a
  side-branch commit. Look at the commit in the approval prompt.
- **Published channel:** the GitHub release and the updater-feed pull request use the
  workflow token, which is not an environment secret. The control there is who can create
  the tag, so the tag ruleset below is required, together with code-owner review of
  workflow changes.

While one person is the only maintainer, the approval is a deliberate confirmation step and
a ref restriction, not two-person control. It does not defend against a compromised owner
account. A second reviewer is the upgrade path.

One-time repository settings, in this order (each step keeps the previous setup working
until the last one):

1. Merge the workflow change. This alone is not protective: if the `release` environment
   does not exist yet, GitHub creates it without reviewers on the first run.
2. Create the `release` environment (Settings → Environments). Add the owner as required
   reviewer and leave "Prevent self-review" off while the owner is the only maintainer.
   Under deployment rules choose "Selected branches and tags" and add the branch `main`
   and the tags `v[0-9]*` and `[0-9]*`. A tag run has `GITHUB_REF=refs/tags/...` and a
   recovery dispatch has `refs/heads/main`, so both kinds are needed. If GitHub rejects a
   tag pattern, widen to `v*` and `*`; the workflow's strict tag check still applies.
3. Copy the eight secrets from the table above into the `release` environment, and copy
   `ASC_KEY_B64`, `ASC_KEY_ID` and `ASC_ISSUER_ID` into the `testflight` environment.
4. Verify: `gh api repos/The-PatientZero/yank/environments/release` shows the reviewer,
   `gh api repos/The-PatientZero/yank/environments/release/deployment-branch-policies`
   lists exactly the three rules, `gh secret list --env release` and
   `gh secret list --env testflight` show the names above, and one approval-gated run
   (or a TestFlight dispatch for the `testflight` copies) succeeds.
5. Only then delete the repository-level copies of `BUILD_CERTIFICATE_BASE64`,
   `P12_PASSWORD`, `APPLE_SIGN_IDENTITY`, `MAC_PROVISIONING_PROFILE_B64`, `TAP_PUSH_TOKEN`,
   `ASC_KEY_B64`, `ASC_KEY_ID` and `ASC_ISSUER_ID`. Keep `APPLE_TEAM_ID`. Until step 5 the
   old copies remain as a rollback.

Doing step 3 or step 5 before step 1 breaks the next tag, because the previous job had no
environment. Deleting the `ASC_*` repository secrets before they exist in `testflight`
fails the next TestFlight dispatch at its cloud-signing step.

Tag ruleset (Settings → Rules → Rulesets): target tags matching `v*` and `[0-9]*`, restrict
creation to the owner and block updates, so a tag cannot be moved. Block deletion with the
owner on the bypass list. That lets the owner remove an unpublished tag whose run was
rejected or expired; a published tag is still never deleted or moved.

Setting "Workflow permissions" to read-only is good hygiene but not a control: a workflow
that declares its own `permissions` is not bound by it.

A tag whose run was rejected or expired has no release and installed apps see nothing new.
Fix the cause and either delete that unpublished tag (owner bypass) and tag again, or
re-run the workflow with the same tag from `main`.

Local releases still work without CI: put `APP_NAME`, `TEAM_ID`, `SIGN_IDENTITY`, and
`NOTARY_PROFILE` in `.env` and run `./scripts/build_dmg.sh`, extract notes with
`bash scripts/extract_release_notes.sh <tag>`, then create the GitHub release with
`--notes-file`, refresh `releases.json`, and run `./scripts/update_homebrew_cask.sh <version>`
by hand.

## TestFlight promotion

The `TestFlight` workflow is a manual, `main`-only release path. It reruns the
package, generated-project, macOS, and iOS simulator gates before its protected
job can read Apple credentials. It then selects the next build number from live
App Store Connect data, archives and validates all three iOS bundles, uploads the
build, waits for Apple processing, assigns the exact build to the configured
internal group, and verifies that relationship.

Promotion is a three-rung ladder, and each rung is a deliberate act:

| Rung | How it runs |
|---|---|
| Internal testers | Every dispatch. No input needed. |
| External testers + Beta App Review | Only when the dispatch sets `promote_external`. |
| App Store release | Never from this workflow. Separate, manual. |

A default dispatch stops at internal. `promote_external` additionally assigns the
same processed build to `TESTFLIGHT_EXTERNAL_GROUP_ID` and submits it to Beta App
Review; the run fails if that review does not reach `WAITING_FOR_REVIEW`,
`IN_REVIEW`, or `APPROVED`. The job summary states which rungs the run climbed —
read it rather than assuming a fixed promotion shape.

Configure a GitHub environment named `testflight`, restrict it to `main`, and
add a required reviewer when the repository plan supports that protection.
Store only the dedicated TestFlight key in this environment:

| Environment secret | Value |
|---|---|
| `TESTFLIGHT_ASC_KEY_B64` | Dedicated App Store Connect API `.p8`, base64-encoded |
| `TESTFLIGHT_ASC_KEY_ID` | Key ID for that dedicated key |
| `TESTFLIGHT_ASC_ISSUER_ID` | Team issuer ID from App Store Connect → Integrations |
| `IOS_DEVELOPMENT_CERTIFICATE_P12_B64` | One Apple Development certificate with its private key (`.p12`), base64-encoded |
| `IOS_DEVELOPMENT_CERTIFICATE_PASSWORD` | Password of that `.p12` |

Every runner starts with an empty keychain. Without the stored certificate, automatic
signing creates a new Apple Development certificate on each run, and the team soon hits
Apple's certificate limit, which fails the archive. The workflow imports the stored one,
then checks that the archive was signed with it and fails if Xcode made a new one.
Create it once: generate a private key and certificate signing request with `openssl`,
create an Apple Development certificate from the request under Certificates,
Identifiers & Profiles, combine the downloaded certificate and the key into a `.p12`,
and store both secrets with `gh secret set --env testflight`. When the certificate
expires or is revoked, the check fails; create a new one the same way.

Add these non-secret environment variables:

| Environment variable | Value |
|---|---|
| `TESTFLIGHT_APP_ID` | Opaque App Store Connect app resource ID, not the bundle ID |
| `TESTFLIGHT_INTERNAL_GROUP_ID` | Opaque ID of the intended internal beta group |
| `TESTFLIGHT_EXTERNAL_GROUP_ID` | Opaque ID of the external beta group. Only needed if you ever dispatch with `promote_external`; an internal-only run does not read or validate it |

The workflow reuses the repository-level `APPLE_TEAM_ID` secret shared with the macOS
release workflow; do not duplicate that identifier into the environment. Its
cloud-signing export step also reads `ASC_KEY_B64`, `ASC_KEY_ID` and `ASC_ISSUER_ID`
from this environment: these are the same shared App Store Connect values the macOS
release uses for notarization, stored as `testflight` environment secrets next to the
`TESTFLIGHT_*` ones. The dedicated TestFlight key (the `TESTFLIGHT_*` secrets) uses App
Manager access and stays separate. Do not broaden it to Admin. App Store Connect team
keys apply across the team, so the dedicated GitHub environment is the credential access
boundary. Never reuse the Developer ID certificate for this workflow.

To promote:

1. Confirm `main` contains the intended release-candidate commit and that
   `MARKETING_VERSION` in `project.yml` is correct.
2. In GitHub, open Actions → TestFlight → Run workflow, keep the branch set to
   `main`, leave `promote_external` unchecked, and approve the protected
   environment job when prompted.
3. Treat the workflow as successful only when its summary reports archive
   validation, Apple processing, and internal-group assignment as verified.
4. Run the physical-device smoke matrix from `docs/iOS_DEVICE_QA.md` against
   that exact TestFlight version/build and record it with
   `docs/IOS_RELEASE_EVIDENCE_TEMPLATE.md`.
5. Only after that device evidence passes, dispatch again with
   `promote_external` checked if the build should reach external testers. Beta
   App Review is Apple's gate and can reject; it is not a formality.

An Xcode upload receipt is not processing proof, and processing is not internal
distribution proof. Internal assignment is likewise not external distribution
proof. Simulator CI also cannot validate App Group access on physical devices,
keyboard insertion, CloudKit push delivery, iCloud account state, file
protection, or accessibility on the signed build. App Store submission remains a
manual, separately authorized gate outside this workflow. The app is free and
open source on both platforms — no purchase, StoreKit IAP, or storefront setup.

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
