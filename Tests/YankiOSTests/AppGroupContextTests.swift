import Foundation
import Testing
import UniformTypeIdentifiers
@testable import YankiOS

@Suite struct AppGroupContextTests {
    @Test func derivesEverySharedPathFromInjectedContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupContextTests-\(UUID().uuidString)", isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: "AppGroupContextTests.\(UUID().uuidString)"))
        let context = AppGroupContext(containerURL: root, defaults: defaults)

        #expect(context.historyURL.deletingLastPathComponent() == root)
        #expect(context.tombstonesURL.deletingLastPathComponent() == root)
        #expect(context.blobsURL.deletingLastPathComponent() == root)
        #expect(context.keyboardProjectionURL.deletingLastPathComponent() == root)
        #expect(context.shareInbox.rootURL == root)
    }

    @Test func identifierRemainsCompatibleWithShippedEntitlements() {
        #expect(AppGroupContext.identifier == "group.com.thepatientzero.yank")
    }

    @Test("Injected App Group accepts a canonical destination for a new synced blob")
    func injectedAppGroupAcceptsCanonicalBlobDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupContextTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "AppGroupContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = AppGroupContext(containerURL: root, defaults: defaults)
        let filename = "9F3A1B2C-4D5E-6F70-8192-A3B4C5D6E7F8.txt"

        let destination = try #require(
            SyncBlobPolicy.containedURL(
                directory: context.blobsURL,
                filename: filename,
                kind: .text
            )
        )

        #expect(destination.lastPathComponent == filename)
    }

    @Test("Pasteboard origin identity is stable and derived from the fork bundle identifier")
    func pasteboardOriginIdentityIsStableAndBundleDerived() throws {
        let suiteName = "AppGroupContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = AppGroupContext(
            containerURL: FileManager.default.temporaryDirectory,
            defaults: defaults
        )
        let expectedToken = try #require(UUID(uuidString: "09082DC7-848A-4DE2-BC11-95CC4A544FF9"))

        let first = try #require(
            context.pasteboardOriginMarkerForWrite(
                bundleIdentifier: "org.example.yank-fork",
                generateToken: { expectedToken }
            )
        )
        let second = try #require(
            context.pasteboardOriginMarkerForWrite(
                bundleIdentifier: "org.example.yank-fork",
                generateToken: {
                    Issue.record("An existing installation token must be reused")
                    return UUID()
                }
            )
        )

        #expect(first == second)
        #expect(first.pasteboardType == "org.example.yank-fork.pasteboard-origin")
        #expect(first.tokenData == Data(expectedToken.uuidString.utf8))
        #expect(!first.pasteboardType.contains("thepatientzero"))
    }

    @Test("Missing and corrupt origin tokens never claim an external pasteboard item")
    func missingAndCorruptOriginTokensFailSafe() throws {
        let suiteName = "AppGroupContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = AppGroupContext(
            containerURL: FileManager.default.temporaryDirectory,
            defaults: defaults
        )

        #expect(
            context.existingPasteboardOriginMarker(
                bundleIdentifier: "org.example.yank-fork"
            ) == nil
        )

        let oldToken = try #require(UUID(uuidString: "59AF5B35-0F42-4A00-9536-B9D780F9B334"))
        let oldMarker = try #require(
            context.pasteboardOriginMarkerForWrite(
                bundleIdentifier: "org.example.yank-fork",
                generateToken: { oldToken }
            )
        )
        defaults.set(
            "not-an-installation-token",
            forKey: IOSPasteboardOriginMarker.tokenDefaultsKey
        )
        #expect(
            context.existingPasteboardOriginMarker(
                bundleIdentifier: "org.example.yank-fork"
            ) == nil
        )
        #expect(
            context.existingPasteboardOriginMarker(bundleIdentifier: nil) == nil
        )

        let replacementToken = try #require(
            UUID(uuidString: "8089B717-9F9D-4CA2-A809-4D26FBE2F6C2")
        )
        let replacementMarker = try #require(
            context.pasteboardOriginMarkerForWrite(
                bundleIdentifier: "org.example.yank-fork",
                generateToken: { replacementToken }
            )
        )
        let types = [replacementMarker.pasteboardType]

        #expect(
            defaults.string(forKey: IOSPasteboardOriginMarker.tokenDefaultsKey)
                == replacementToken.uuidString
        )
        #expect(
            !oldMarker.matches(pasteboardTypes: types) { _ in
                replacementMarker.tokenData
            }
        )
        #expect(
            replacementMarker.matches(pasteboardTypes: types) { _ in
                replacementMarker.tokenData
            }
        )
    }

    @MainActor
    @Test("Text pasteboard writes contain content and origin marker in one item")
    func buildsAtomicTextPasteboardItem() throws {
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("installation-token".utf8)
        )

        let items = IOSPasteboardItemBuilder.text("exact text", marker: marker)
        let item = try #require(items.first)

        #expect(items.count == 1)
        #expect(item.count == 2)
        #expect(item[UTType.utf8PlainText.identifier] as? String == "exact text")
        #expect(item[marker.pasteboardType] as? Data == marker.tokenData)
    }

    @MainActor
    @Test("Image pasteboard writes contain PNG bytes and origin marker in one item")
    func buildsAtomicImagePasteboardItem() throws {
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("installation-token".utf8)
        )
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])

        let items = IOSPasteboardItemBuilder.imagePNG(pngData, marker: marker)
        let item = try #require(items.first)

        #expect(items.count == 1)
        #expect(item.count == 2)
        #expect(item[UTType.png.identifier] as? Data == pngData)
        #expect(item[marker.pasteboardType] as? Data == marker.tokenData)
    }

    @MainActor
    @Test("An external replacement race is never reported as Yank's handled generation")
    func doesNotClaimExternalGenerationAfterWriteRace() {
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("installation-token".utf8)
        )
        let items = IOSPasteboardItemBuilder.text("Yank value", marker: marker)
        var changeCount = 10
        var currentTypes: [String] = []
        var dataByType: [String: Data] = [:]
        var setItemsCallCount = 0

        let handledGeneration = IOSPasteboardItemBuilder.writeAndValidateCurrentGeneration(
            items,
            marker: marker,
            setItems: { writtenItems in
                setItemsCallCount += 1
                #expect(writtenItems.count == 1)
                // Yank's generation 11 is immediately replaced by an external writer.
                changeCount = 12
                currentTypes = [UTType.utf8PlainText.identifier]
                dataByType = [:]
            },
            readChangeCount: { changeCount },
            readTypes: { currentTypes },
            readData: { dataByType[$0] }
        )

        #expect(handledGeneration == nil)
        #expect(setItemsCallCount == 1)
    }

    @MainActor
    @Test("A replacement during origin-tag validation invalidates the written generation")
    func doesNotClaimGenerationReplacedDuringMarkerRead() {
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("installation-token".utf8)
        )
        let items = IOSPasteboardItemBuilder.text("Yank value", marker: marker)
        var changeCount = 10
        var currentTypes: [String] = []

        let handledGeneration = IOSPasteboardItemBuilder.writeAndValidateCurrentGeneration(
            items,
            marker: marker,
            setItems: { _ in
                changeCount = 11
                currentTypes = [UTType.utf8PlainText.identifier, marker.pasteboardType]
            },
            readChangeCount: { changeCount },
            readTypes: { currentTypes },
            readData: { _ in
                let matchingData = marker.tokenData
                changeCount = 12
                currentTypes = [UTType.utf8PlainText.identifier]
                return matchingData
            }
        )

        #expect(handledGeneration == nil)
    }

}
