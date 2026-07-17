import Foundation
import Testing
@testable import YankiOS

@Suite
@MainActor
struct ClipStoreExtensionHandoffTests {
    @Test func missingAppGroupFailsClosed() {
        let store = ClipStore(context: nil)

        #expect(store.storageUnavailable)
        #expect(store.items.isEmpty)
    }

    @Test func importsPendingTextDurablyThenRemovesEntry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.context.shareInbox.enqueue(
            text: "shared text",
            sourceApp: "Share",
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 42)
        )
        let store = ClipStore(context: fixture.context)

        await store.drainShareInbox()

        #expect(store.items.first?.id == entry.id)
        #expect(store.items.first?.textContent == "shared text")
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.first?.id == entry.id)
    }

    @Test func retryOfAlreadyImportedEntryDoesNotDuplicateIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let store = ClipStore(context: fixture.context)
        _ = try fixture.context.shareInbox.enqueue(text: "once", id: id)
        await store.drainShareInbox()
        _ = try fixture.context.shareInbox.enqueue(text: "once", id: id)

        await store.drainShareInbox()

        #expect(store.items.filter { $0.id == id }.count == 1)
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
    }

    @Test func overlappingDrainsImportEachEntryOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        _ = try fixture.context.shareInbox.enqueue(
            text: String(repeating: "overlap", count: 10_000),
            id: id
        )
        let store = ClipStore(context: fixture.context)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.drainShareInbox() }
            group.addTask { await store.drainShareInbox() }
        }

        #expect(store.items.filter { $0.id == id }.count == 1)
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
    }

    @Test func malformedEntryDoesNotBlockValidCaptureOrPoisonStore() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let valid = try fixture.context.shareInbox.enqueue(text: "valid")
        let corruptedURL = fixture.context.shareInbox.entriesURL.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: corruptedURL)
        let store = ClipStore(context: fixture.context)

        await store.drainShareInbox()

        #expect(store.items.contains { $0.id == valid.id })
        #expect(!store.storageUnavailable)
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
    }

    @Test func missingImagePayloadDoesNotBlockLaterValidCapture() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let broken = try fixture.context.shareInbox.enqueue(
            imagePNG: Data([1, 2, 3]),
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let payloadURL = fixture.context.shareInbox.payloadsURL
            .appendingPathComponent(broken.id.uuidString)
            .appendingPathExtension("png")
        try FileManager.default.removeItem(at: payloadURL)
        let valid = try fixture.context.shareInbox.enqueue(
            text: "valid after broken image",
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let store = ClipStore(context: fixture.context)

        await store.drainShareInbox()

        #expect(store.items.contains { $0.id == valid.id })
        #expect(!store.storageUnavailable)
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
    }

    @Test func failedFlushIsRetriedBeforeTheHandoffIsRemoved() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.context.shareInbox.enqueue(text: "survives failed flush")
        let store = ClipStore(context: fixture.context)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        await store.drainShareInbox()

        #expect(store.items.contains { $0.id == entry.id })
        #expect(try fixture.context.shareInbox.pendingEntries() == [entry])

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        await store.drainShareInbox()

        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
        let reloaded = ClipStore(context: fixture.context)
        #expect(reloaded.items.contains { $0.id == entry.id })
    }

    @Test func touchUsesSharedMoveToTopMutation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        await store.capture(text: "first")
        await store.capture(text: "second")
        let first = try #require(store.items.first { $0.textContent == "first" })

        store.touch(first)

        #expect(store.items.first?.id == first.id)
    }

    @Test func reconcileKeepsBlobsUntilReplacementSnapshotIsDurable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        #expect(await store.captureImage(pngData: Data([0x89, 0x50, 0x4E, 0x47])))
        try store.flushPendingWrites()
        let filename = try #require(store.items.first?.imageFilename)
        let blobURL = try #require(
            SyncBlobPolicy.containedURL(
                directory: fixture.context.blobsURL,
                filename: filename,
                kind: .image
            )
        )

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        #expect(throws: (any Error).self) {
            try store.applyReconciledDurably([])
        }
        #expect(FileManager.default.fileExists(atPath: blobURL.path))

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try store.applyReconciledDurably([])
        #expect(!FileManager.default.fileExists(atPath: blobURL.path))
    }

    @Test func reconcileKeepsDeferredBlobWhenReferencedAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        #expect(await store.captureImage(pngData: Data([0x89, 0x50, 0x4E, 0x47])))
        try store.flushPendingWrites()
        let item = try #require(store.items.first)
        let filename = try #require(item.imageFilename)
        let blobURL = try #require(
            SyncBlobPolicy.containedURL(
                directory: fixture.context.blobsURL,
                filename: filename,
                kind: .image
            )
        )

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )
        #expect(throws: (any Error).self) {
            try store.applyReconciledDurably([])
        }

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try store.applyReconciledDurably([item])

        #expect(FileManager.default.fileExists(atPath: blobURL.path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipStoreExtensionHandoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "ClipStoreExtensionHandoffTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        return Fixture(
            root: root,
            defaultsName: defaultsName,
            context: AppGroupContext(containerURL: root, defaults: defaults)
        )
    }

    private struct Fixture {
        let root: URL
        let defaultsName: String
        let context: AppGroupContext

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
    }
}
