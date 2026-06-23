// swift-tools-version:6.0
import PackageDescription

// YankCore — the platform-agnostic core shared by the macOS app and the iOS app.
// It lives in the standard `Sources/YankCore` layout (NOT `path: "."`): with the
// package root as the target path, llbuild's directory-structure scan recursively
// stats the whole repo — following any symlink it finds (e.g. a DMG-staging
// `Applications -> /Applications`) and ballooning its build database to tens of GB.
// A dedicated source directory keeps that scan tiny and stable. The macOS/iOS Xcode
// targets reference these same files in place via project.yml, so there's still no
// duplication and no module import across the app/core boundary.
//
// The Xcode app target already builds this code with `SWIFT_VERSION = 6.0` and
// complete strict concurrency. Pinning the package to the same mode makes
// `swift test` enforce the identical concurrency rules, so the test target can't
// pass under weaker checking than ships.
let package = Package(
    name: "YankCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "YankCore", targets: ["YankCore"]),
        .library(name: "YankCloudKitSync", targets: ["YankCloudKitSync"])
    ],
    targets: [
        .target(
            name: "YankCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "YankCloudKitSync",
            dependencies: ["YankCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "YankCoreTests",
            dependencies: ["YankCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "YankCloudKitSyncTests",
            dependencies: ["YankCore", "YankCloudKitSync"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
