# Yank — Handoff (post-audit hardening + architecture refactor)

> **Working doc — do NOT commit this file.** Delete it once Task C (commit) is done.
> Audience: the engineering agent taking over to support the maintainer's manual testing
> and then commit. The maintainer (`The-PatientZero`) drives testing; you assist + commit.

---

## 1. Snapshot

- **Repo:** `/Users/mehmetkoksal/Documents/Projects/Personal/yank` — Yank, a private macOS + iOS clipboard manager. Swift 6 (strict concurrency), SwiftUI + AppKit, **zero third-party deps**, XcodeGen (`project.yml` is source of truth), CloudKit private-DB sync, on-device Apple Foundation Models.
- **HEAD:** `6cb1ad1 docs: add design system reference`. **Everything below is uncommitted** (working tree).
- **Status — all green as of handoff:**
  - `swift test` → **356 pass** (YankCore + YankCloudKitSync; +14 added this work).
  - macOS app build → **BUILD SUCCEEDED**, zero warnings.
  - iOS app + extensions build → **BUILD SUCCEEDED**.
- **Working tree:** broad uncommitted feature, hardening, and architecture work. `Views/` and `Services/` are directory-globbed into the macOS target, so new files there are auto-included on `xcodegen generate` — but they still must be `git add`ed when committing.

### Re-verify before doing anything (fresh checkout)
```bash
cd /Users/mehmetkoksal/Documents/Projects/Personal/yank
xcodegen generate
swift test
xcodebuild -project Yank.xcodeproj -scheme Yank   -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Yank.xcodeproj -scheme YankiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```

---

## 2. What changed (scope you're inheriting)

Three layers of work sit uncommitted on top of `6cb1ad1`:

1. **Feature work (pre-existing):** opt-in on-device Apple Intelligence (tag/title suggestions, Smart Paste rewrites, natural-language search).
2. **Full audit + remediation (this session):** all 34 findings from a comprehensive audit were addressed. Highlights:
   - **AI-field sync (ARCH-001/TEST-001):** `ClipboardMerge` now carries AI enrichment forward on its own clock so a metadata edit from a non-enriching device can't erase Mac-computed tags/titles. Round-trip tests added.
   - **iOS keyboard memory (OEM-001):** iOS text capture now applies the Mac's `TextCapturePlan` size policy (inline ≤50 KB, else file-backed, else truncated) and the keyboard scans `store.items` lazily — no second full-text copy.
   - **Resilient history decode (ARCH-004):** one malformed clip no longer locks out the whole history.
   - Update downgrade floor (SEC-004), CloudKit blob-redownload skip (PERF-002), Spotlight redaction (OEM-002), docs accuracy (SECURITY/README/CHANGELOG), + smaller design/test/code fixes.
   - **Consciously rejected:** PERF-001 (reusing a `LanguageModelSession` would bleed one clip's transcript into the next — fresh-per-call is correct).
3. **Architecture refactor (ARCH-003 + ARCH-005, this session):**
   - God-modules split (behavior-preserving, via same-type extensions / a new type): `HistoryContentView` 980→372 (+`HistoryContentView+{Selection,KeyCommands,Layouts,ImageExport}.swift`), `SettingsView` 936→239 (+6 `Settings*Section.swift` + 9 consolidated `SettingsManager` setters), `ClipboardStore` 769→564 (+`ClipBlobStore.swift`).
   - **Settings dependency injection:** a single `SettingsManager` is owned by `AppDelegate` and threaded through `ClipboardController` → controllers (`HistoryWindowController`, `QuickPickerWindowController`, `HubController`, `WelcomeWindowController`, `HistoryPanel`) and SwiftUI views (`HistoryContentView` → `SettingsView`/`HistoryEmptyState`; `CaptureExclusionSection`, `ViewModePicker`) and `ClipEnrichmentService`. Every injection point **defaults to `.shared`**, so runtime behavior is provably identical.

**Intentionally-kept globals (do NOT "fix" these — they are deliberate, build-verified decisions):**
`Haptics.fire`/`Sounds.play` (static leaf feedback utils reading one bool), `AppTheme.active` (theming accessor read at dozens of accent sites — a separate theme-environment concern), the `HistoryContentView` `@State` initial seeds and `AppDelegate.clipboardStore` (Swift constraint: a property initializer can't reference `self`).

---

## 3. Task A — Build a signed, notarized DMG (required for full testing)

**Why signed:** an unsigned source build (`⌘R` in Xcode) runs **local-only**. CloudKit sync needs the iCloud-container entitlement that only a Developer ID export embeds, and the in-app updater verifies codesign/notarization. So:

| Feature area | Unsigned `⌘R` build | Signed/notarized DMG |
|---|---|---|
| On-device AI, paste, layouts, settings, retention | ✅ testable | ✅ |
| **CloudKit sync** (incl. the AI-field carry-forward, cross-device, mixed-build) | ❌ local-only | ✅ required |
| **In-app update flow** (SEC-004 downgrade floor, signature/notarization checks) | ❌ | ✅ required |

**The signed build is `scripts/build_dmg.sh`** — it does archive → Developer ID export (embeds the iCloud-authorizing profile) → DMG → sign → **notarize → staple → validate**, and also emits the updater ZIP + `.sha256` sidecars into `build/dist/`.

**Prerequisites (the maintainer's Apple Developer credentials — these can't be guessed):**
1. Create `.env` in the repo root from `.env.example`, defining:
   - `APP_NAME` (e.g. `Yank`), `TEAM_ID` (Apple Developer Team ID), `SIGN_IDENTITY` (`"Developer ID Application: <Name> (<TEAM_ID>)"`), `NOTARY_PROFILE` (a `notarytool` keychain profile name).
   - `.env` is git-ignored — never commit it, never print its contents.
2. A **Developer ID Application** certificate in the login keychain, and an Xcode account logged in (for automatic signing locally) with the iCloud capability on the profile for `com.thepatientzero.yank`.
3. A notary profile: `xcrun notarytool store-credentials <NOTARY_PROFILE> --apple-id … --team-id … --password <app-specific-pw>` (one-time).
4. `xcodegen` on PATH (`scripts/install_xcodegen.sh` if missing).

**Run:**
```bash
./scripts/build_dmg.sh
# → build/dist/Yank.dmg  (signed · notarized · stapled · universal)
# → build/dist/Yank-<version>-universal.zip (+ .sha256)  for the updater
```
Notarization can be slow on macOS 26 — that's expected.

> **Agent note:** signing/notarization needs the maintainer's account + secrets. If they aren't configured in this environment, prepare everything, then have the maintainer run `./scripts/build_dmg.sh` themselves (suggest they type `! ./scripts/build_dmg.sh` in the session). Do not attempt to fabricate certs/profiles. CI path for reference: `.github/workflows/release.yml`.

---

## 4. Task B — Manual test checklist (support the maintainer)

Set a Development Team in Xcode for `⌘R` local runs. Items marked **[signed]** need the DMG installed to `/Applications`.

**On-device AI** (Settings → "Suggest tags & titles"; needs Apple Intelligence available, macOS 26+):
- Copy several text snippets → in ⇧⌘V, dashed suggested-tag chips appear; tapping one promotes it.
- Copy a long passage (≥200 chars) → its row shows an AI title.
- Right-click a text clip in ⇧⌘V → **Smart Paste ▸** → e.g. Proofread → transformed text pastes.
- Type a phrase in ⇧⌘V → click the text-magnifyingglass **Interpret** button → a spinner shows, then smart results.

**Settings (verify the split + DI didn't regress anything):** open Settings and toggle/change each control — **menu-bar icon, Spotlight, AI tagging, sync, theme/accent, view mode, density, hotkey, history limit, retention, capture exclusions** — and confirm each still takes effect live (these reads were rewired to the injected `SettingsManager`, so this is the key regression surface).

**History window:** all layouts (list/grid/masonry/gallery/split), search, tag filter, multi-select, paste/copy/pin/bookmark/tag, delete + undo banner, empty/loading states.

**[signed] CloudKit sync:** sign in to iCloud on two devices (Mac DMG + iPhone). Verify: clips sync both ways; **pin/tag an AI-enriched clip on one device → the AI tags/title survive on the other** (the ARCH-001 fix); a clip enriched on Mac shows its title on iPhone.

**[signed] Update flow:** confirm the in-app updater offers/stages/installs and that it refuses a same-or-older version (downgrade floor).

**iOS (simulator ok for most; device for memory):** keyboard extension with Full Access — type to filter, insert a clip; with a large history + a multi-MB text clip, confirm the keyboard doesn't get jetsam-killed (device). Share extension (text + image). Action-button App Intent. Spotlight indexing (when enabled) shows only a redacted first-line snippet, not full clip bodies.

Capture findings as you go; anything that fails blocks the relevant commit.

---

## 5. Task C — Commit (ONLY after the maintainer confirms verification)

**Absolute rules (from the maintainer's global config — non-negotiable):**
- **NEVER add `Co-Authored-By`, `Signed-off-by`, or any co-author / AI / agent attribution.** No references to AI, assistants, or agent names in messages or metadata. All commits are solely the maintainer's.
- **Conventional Commits:** `type(scope): description`, imperative, English. Lean — one-line subject by default; short body only when the *why* isn't obvious. One logical change per commit; each commit must build + test.
- **Don't push** unless explicitly asked. Don't `--no-verify`, don't force-push.
- Project is pre-1.0, unshipped, sole contributor → committing straight to `main` is acceptable here (no PR ceremony required unless the maintainer asks).
- `git add` the 28 new files; **do not commit `.env` or this `HANDOFF.md`** (delete HANDOFF.md after).

**Recommended commit structure** (the feature, hardening, and refactor interleave across the same files, so a clean split needs `git add -p` hunk staging — confirm the maintainer's preference for **one** vs **a few**):
- `feat(intelligence): add opt-in on-device tag/title, smart paste, NL search`
- `refactor(settings): inject SettingsManager from the composition root`
- `refactor: split history/settings/store god-modules into focused files`
- `fix: audit hardening (AI-sync carry-forward, iOS text cap, a11y, resilient decode, update floor)`
- `docs: describe on-device AI in README/SECURITY/CHANGELOG`

If hunk-staging proves impractical, a single `feat: on-device intelligence, with audit hardening + architecture refactor` is acceptable given it's one cohesive pre-1.0 push. Re-run the three verification builds + `swift test` on the staged tree before each commit.

---

## 6. Guardrails (keep these true)

- **Zero third-party dependencies** — never add a package.
- **Design system** — use tokens (`Space`, `Radius`, `TypeScale`, `IconSize`, `YankInk`/`Color.yank*`, `YankMotion`); accent foregrounds use `AppTheme.active.foreground`, never the saturated `color` as a glyph. Ref: `docs/DESIGN-SYSTEM.md`.
- **Trust the build over live SourceKit** — after adding fields to `ClipboardItem` etc., SourceKit may transiently report "no member"; `swift test`/`xcodebuild` are authoritative.
- Don't revert the intentionally-kept globals (§2) or the behavior-preserving `.shared` defaults.
- Don't read `.env` / secrets / `*.pem` / `*.key`.

## Key file map
- Composition root: `AppDelegate.swift`, `Services/ClipboardController.swift` (+ `ClipboardDependencies`).
- Settings: `Services/SettingsManager.swift` (now has `setX(...)` consolidated setters), `Views/Settings*Section.swift`.
- AI: `Sources/YankCore/{ClipEnricher,SmartQuery,TextTransform}.swift`, `Services/FoundationModel*.swift`, `Services/ClipEnrichmentService.swift`.
- Sync/merge: `Sources/YankCore/ClipboardMerge.swift`, `Sources/YankCloudKitSync/CloudKitSync.swift`.
- iOS: `iOS/ClipStore.swift` (+`+Mutations`), `iOS/KeyboardViewController.swift`, `iOS/ShareViewController.swift`, `iOS/CaptureClipIntent.swift`, `Shared/SpotlightIndexer.swift`.
- DMG/release: `scripts/build_dmg.sh`, `scripts/ExportOptions.plist`, `.github/workflows/release.yml`.
