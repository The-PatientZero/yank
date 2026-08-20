# Contributing to Yank

Thanks for helping improve Yank. The repository is designed so every non-device quality gate can
run from a clean checkout without maintainer credentials, private planning files, or Apple signing.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- Swift 6
- Command Line Tools supplied with Xcode

Install the repository-pinned XcodeGen build. The installer verifies the source archive checksum
and prints the installed executable path:

```bash
XCODEGEN_BIN="$(scripts/install_xcodegen.sh)"
```

Do not add signing identities, provisioning profiles, `.env` files, or App Store Connect
credentials to the repository. Unsigned builds run local-only; CloudKit and physical extension
handoff require signed builds and are maintainer release gates.

## Required checks

Run these commands from the repository root:

```bash
# Install and select the checksum-verified project generator
XCODEGEN_BIN="$(scripts/install_xcodegen.sh)"

# Package tests, public-link checks, and plist/privacy-manifest validation
swift test

# Generate the app project from its tracked source of truth
"$XCODEGEN_BIN" generate

# macOS app and app-unit tests
xcodebuild \
  -project Yank.xcodeproj \
  -scheme Yank \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test

# iOS app, keyboard/share extensions, and iOS-unit tests
xcodebuild \
  -project Yank.xcodeproj \
  -scheme YankiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The package test suite validates every tracked property list and privacy manifest and checks
relative links in public Markdown. `project.yml` is the source of truth for `Yank.xcodeproj`;
regenerate the project whenever sources or target settings change.

Physical iPhone/iPad, App Group, keyboard insertion, Share extension, CloudKit push, VoiceOver,
and TestFlight checks are release gates documented in
[`docs/iOS_DEVICE_QA.md`](docs/iOS_DEVICE_QA.md), not substitutes for the commands above.

## Change expectations

- Keep changes focused and include regression tests with production-code changes.
- Preserve clipboard privacy: do not log or upload captured content.
- Do not weaken size limits, file protection, synchronization receipts, or accessibility behavior.
- Use Conventional Commit subjects such as `fix(sync): preserve failed push receipts`.
- Update [`CHANGELOG.md`](CHANGELOG.md) for user-visible changes.

## Comments

A comment earns its place only by stating something the code cannot: an invariant, an
ordering or crash-safety constraint, a platform or API quirk, or a deliberate tradeoff.

- Keep it to one to three lines. If it needs more, restructure the code instead.
- Never narrate what the next line does, describe a past change, or address a reviewer.
- Public API gets a one-sentence doc comment stating the contract, not the implementation.
- State a rationale once, at the declaration that owns it; reference it elsewhere.
- No commented-out code. A `TODO` names the release or issue that retires it.

Security reports should follow [`SECURITY.md`](SECURITY.md). General support belongs in
[`SUPPORT.md`](SUPPORT.md).
