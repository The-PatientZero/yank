# Yank For iOS

The iOS app is built on shared `YankCore` logic for the clipboard model, retention policy, capture
rules, and CloudKit mapping. Capture on iOS is manual by design: the Mac captures continuously,
while iOS adds clips through the app, keyboard extension, share extension, and App Intent.

## Build

The iOS targets are generated from `project.yml` with XcodeGen. The project targets iOS 17+.

```bash
xcodegen generate
xcodebuild \
  -project Yank.xcodeproj \
  -scheme YankiOS \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Device runs, CloudKit, App Groups, and extension QA require an Apple Developer account and real
provisioning.

Before a public iOS build or release candidate, run the physical-device matrix in
[`docs/iOS_DEVICE_QA.md`](../docs/iOS_DEVICE_QA.md).

## Sources

| File | Role |
|---|---|
| `iOS/YankApp.swift` | App entry; starts sync and Spotlight indexing when available |
| `iOS/HistoryView.swift` | Browse/search synced clips, tap to open details, batch actions |
| `iOS/ClipStore.swift` | iOS store backed by App Group JSON, conforms to `SyncableStore` |
| `iOS/KeyboardViewController.swift` | Keyboard extension for inserting recent clips |
| `iOS/ShareViewController.swift` | Share extension for capturing shared text and URLs |
| `iOS/CaptureClipIntent.swift` | App Intent for Shortcuts, Action Button, and Back Tap flows |
| `Shared/SpotlightIndexer.swift` | Core Spotlight indexing shared with iOS app code |

## Xcode Targets

The iOS targets are declared in `project.yml`; `Yank.xcodeproj` is generated and ignored by git.

| Target | Type | Bundle id | Core | App sources | Entitlements |
|---|---|---|---|---|---|
| `YankiOS` | Application | `com.thepatientzero.yank` | Full core, including CloudKit sync | iOS app UI, App Intent, Spotlight | `iOS/Yank-iOS.entitlements` |
| `YankKeyboard` | App extension | `com.thepatientzero.yank.keyboard` | Lean core, no CloudKit | Keyboard controller | `iOS/Yank-iOS-Extension.entitlements` |
| `YankShare` | App extension | `com.thepatientzero.yank.share` | Lean core, no CloudKit | Share controller | `iOS/Yank-iOS-Extension.entitlements` |

The extensions use the App Group store and intentionally avoid CloudKit. The container app owns sync.

## External Gates

The App Group (`group.com.thepatientzero.yank`) and CloudKit container
(`iCloud.com.thepatientzero.yank`) must be registered under the publishing team before device
verification. Forks should replace those identifiers with their own before publishing.
