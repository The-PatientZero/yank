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

    @Test func shortcutCaptureUsesInboxAndRefreshesTheLiveStore() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)

        try await CaptureClipIntent.enqueue(
            text: "captured by shortcut",
            in: fixture.context.shareInbox
        )

        #expect(store.items.isEmpty)
        #expect(try fixture.context.shareInbox.pendingEntries().count == 1)

        let successfulSources = await store.drainShareInbox()

        #expect(store.items.first?.textContent == "captured by shortcut")
        #expect(store.items.first?.sourceApp == "Shortcuts")
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
        #expect(successfulSources == ["Shortcuts"])
    }

    @Test func shortcutResolvesStorageBeforeReadingClipboard() async {
        var didReadClipboard = false

        await #expect(throws: CaptureClipIntent.CaptureError.storageUnavailable) {
            try await CaptureClipIntent.captureClipboard(
                resolveAppGroup: { nil },
                readText: {
                    didReadClipboard = true
                    return "must not be read"
                }
            )
        }

        #expect(!didReadClipboard)
    }

    @Test func directExactTextCaptureRefreshesNewestEligibleRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let older = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            sourceApp: "Older Source", textContent: "repeat",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100),
            deviceOrigin: "remote-older"
        )
        let newest = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 200),
            sourceApp: "Newer Source", textContent: "repeat",
            isPinned: true, isBookmarked: true, tags: ["keep"], ocrText: "derived",
            aiTags: ["local"], aiTitle: "Legacy title",
            aiEnrichedAt: Date(timeIntervalSinceReferenceDate: 150),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200),
            deviceOrigin: "remote-newer"
        )
        try writeHistory([older, newest], in: fixture)
        let store = ClipStore(context: fixture.context)

        await store.capture(text: "repeat", sourceApp: "Notes")
        try store.flushPendingWrites()

        #expect(store.items.count == 2)
        let refreshed = try #require(store.items.first)
        #expect(refreshed.id == newest.id)
        #expect(refreshed.timestamp > newest.timestamp)
        #expect(refreshed.modifiedAt == refreshed.timestamp)
        #expect(refreshed.sourceApp == "Notes")
        #expect(refreshed.deviceOrigin == DeviceIdentity.current)
        #expect(refreshed.isPinned)
        #expect(refreshed.isBookmarked)
        #expect(refreshed.tags == ["keep"])
        #expect(refreshed.ocrText == "derived")
        #expect(refreshed.aiTags == ["local"])
        #expect(refreshed.aiTitle == "Legacy title")
        #expect(refreshed.aiEnrichedAt == Date(timeIntervalSinceReferenceDate: 150))
        let untouched = try #require(store.items.first { $0.id == older.id })
        #expect(untouched.timestamp == older.timestamp)
        #expect(untouched.sourceApp == "Older Source")
        #expect(untouched.deviceOrigin == "remote-older")
    }

    @Test func directTextCaptureKeepsRepresentationCollisionsDistinct() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let rich = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 300),
            textContent: "same", richFilename: "rich.plist", hasRichContent: true
        )
        let fileBacked = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 200),
            textContent: "same", textFilename: "11111111-1111-4111-8111-111111111111.txt"
        )
        let truncated = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "same", isTruncated: true, originalSizeBytes: 100_000
        )
        try writeHistory([rich, fileBacked, truncated], in: fixture)
        let store = ClipStore(context: fixture.context)

        await store.capture(text: "same", sourceApp: "Notes")
        try store.flushPendingWrites()

        #expect(store.items.count == 4)
        let inserted = try #require(store.items.first)
        #expect(inserted.id != rich.id)
        #expect(inserted.id != fileBacked.id)
        #expect(inserted.id != truncated.id)
        #expect(inserted.textFilename == nil)
        #expect(!inserted.isTruncated)
        #expect(!inserted.hasRichContent)
    }

    @Test func foregroundRichInlineCapturePersistsRepresentationIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)

        let outcome = await store.captureForegroundText(
            "formatted inline",
            pasteboardGeneration: 70,
            hasRichContent: true
        )

        #expect(outcome == .durable)
        let item = try #require(store.items.first)
        #expect(item.hasRichContent)
        #expect(item.textContent == "formatted inline")
        #expect(item.textFilename == nil)
        #expect(!item.isTruncated)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.first?.hasRichContent == true)
    }

    @Test func foregroundRichFileBackedCapturePersistsRepresentationIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        let text = String(repeating: "f", count: 50_001)

        let outcome = await store.captureForegroundText(
            text,
            pasteboardGeneration: 71,
            hasRichContent: true
        )

        #expect(outcome == .durable)
        let item = try #require(store.items.first)
        #expect(item.hasRichContent)
        #expect(item.textFilename != nil)
        #expect(!item.isTruncated)
        #expect(item.originalSizeBytes == text.utf8.count)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.first?.hasRichContent == true)
        #expect(snapshot.items.first?.textFilename == item.textFilename)
    }

    @Test func foregroundRichTruncatedCapturePersistsRepresentationIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        let text = String(
            repeating: "t",
            count: SyncBlobKind.text.maximumBytes + 1
        )

        let outcome = await store.captureForegroundText(
            text,
            pasteboardGeneration: 72,
            hasRichContent: true
        )

        #expect(outcome == .durable)
        let item = try #require(store.items.first)
        #expect(item.hasRichContent)
        #expect(item.textFilename == nil)
        #expect(item.isTruncated)
        #expect(item.originalSizeBytes == text.utf8.count)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.first?.hasRichContent == true)
        #expect(snapshot.items.first?.isTruncated == true)
    }

    @Test func foregroundPlainAndRichFallbacksRemainDistinctWhilePlainRefreshes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)

        #expect(await store.captureForegroundText(
            "same fallback",
            pasteboardGeneration: 73,
            hasRichContent: false
        ) == .durable)
        let plainID = try #require(store.items.first?.id)

        #expect(await store.captureForegroundText(
            "same fallback",
            pasteboardGeneration: 74,
            hasRichContent: true
        ) == .durable)
        let richID = try #require(store.items.first?.id)

        #expect(await store.captureForegroundText(
            "same fallback",
            pasteboardGeneration: 75,
            hasRichContent: false
        ) == .durable)

        #expect(store.items.count == 2)
        #expect(store.items.first?.id == plainID)
        #expect(store.items.first?.hasRichContent == false)
        #expect(store.items.contains { $0.id == richID && $0.hasRichContent })
        #expect(plainID != richID)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items == store.items)
    }

    @Test func inboxExactTextCaptureRefreshesExistingRecordDurably() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let existing = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            sourceApp: "Share", textContent: "same inbox text",
            isBookmarked: true, tags: ["saved"],
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100),
            deviceOrigin: "remote"
        )
        try writeHistory([existing], in: fixture)
        let store = ClipStore(context: fixture.context)
        let entry = try fixture.context.shareInbox.enqueue(
            text: "same inbox text",
            sourceApp: "Shortcuts",
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 900)
        )

        let successfulSources = await store.drainShareInbox()

        #expect(successfulSources == ["Shortcuts"])
        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
        #expect(store.items.count == 1)
        let refreshed = try #require(store.items.first)
        #expect(refreshed.id == existing.id)
        #expect(refreshed.id != entry.id)
        #expect(refreshed.timestamp == entry.createdAt)
        #expect(refreshed.modifiedAt == entry.createdAt)
        #expect(refreshed.sourceApp == "Shortcuts")
        #expect(refreshed.deviceOrigin == DeviceIdentity.current)
        #expect(refreshed.isBookmarked)
        #expect(refreshed.tags == ["saved"])
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items == store.items)
    }

    @Test func stableHandoffIDRetryDoesNotRefreshCaptureMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let firstDate = Date(timeIntervalSinceReferenceDate: 100)
        let store = ClipStore(context: fixture.context)
        _ = try fixture.context.shareInbox.enqueue(
            text: "retry", sourceApp: "Share", id: id, createdAt: firstDate
        )
        await store.drainShareInbox()
        _ = try fixture.context.shareInbox.enqueue(
            text: "retry", sourceApp: "Shortcuts", id: id,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        await store.drainShareInbox()

        #expect(store.items.count == 1)
        #expect(store.items.first?.id == id)
        #expect(store.items.first?.timestamp == firstDate)
        #expect(store.items.first?.sourceApp == "Share")
    }

    @Test func inboxLargeTextDoesNotDeduplicateAgainstMatchingPreview() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let largeText = String(repeating: "x", count: 50_001)
        let preview = String(largeText.prefix(500))
        let existing = ClipboardItem(
            id: UUID(), type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: preview
        )
        try writeHistory([existing], in: fixture)
        let store = ClipStore(context: fixture.context)
        let entry = try fixture.context.shareInbox.enqueue(
            text: largeText,
            sourceApp: "Share",
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        await store.drainShareInbox()

        #expect(store.items.count == 2)
        #expect(store.items.first?.id == entry.id)
        #expect(store.items.first?.textFilename != nil)
        #expect(store.items.contains { $0.id == existing.id })
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
        let entry = try fixture.context.shareInbox.enqueue(
            text: "survives failed flush",
            sourceApp: "Share"
        )
        let store = ClipStore(context: fixture.context)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        let failedSources = await store.drainShareInbox()

        #expect(store.items.contains { $0.id == entry.id })
        #expect(try fixture.context.shareInbox.pendingEntries() == [entry])
        #expect(failedSources.isEmpty)

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        let successfulSources = await store.drainShareInbox()

        #expect(try fixture.context.shareInbox.pendingEntries().isEmpty)
        #expect(successfulSources == ["Share"])
        let reloaded = ClipStore(context: fixture.context)
        #expect(reloaded.items.contains { $0.id == entry.id })
    }

    @Test func suspensionFlushAwaitsTheLatestHistoryTransaction() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)

        await store.capture(text: "durable before suspension")
        try await store.flushPendingWritesBeforeSuspension()

        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.first?.textContent == "durable before suspension")
    }

    @Test func suspensionFlushPropagatesTheLatestHistoryTransactionFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        await store.capture(text: "must not be acknowledged as durable")

        await #expect(throws: (any Error).self) {
            try await store.flushPendingWritesBeforeSuspension()
        }
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

    @Test func foregroundBlobFailureLeavesTheGenerationRetryable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        let largeText = String(repeating: "blob retry ", count: 5_001)
        try FileManager.default.removeItem(at: fixture.context.blobsURL)
        try Data().write(to: fixture.context.blobsURL)

        let failed = await store.captureForegroundText(
            largeText,
            pasteboardGeneration: 60,
            hasRichContent: false
        )

        #expect(failed == .retryableFailure)
        #expect(store.items.isEmpty)

        try FileManager.default.removeItem(at: fixture.context.blobsURL)
        try FileManager.default.createDirectory(
            at: fixture.context.blobsURL,
            withIntermediateDirectories: true
        )
        let retried = await store.captureForegroundText(
            largeText,
            pasteboardGeneration: 60,
            hasRichContent: false
        )

        #expect(retried == .durable)
        #expect(store.items.count == 1)
        #expect(store.items.first?.textFilename != nil)
    }

    @Test func foregroundSnapshotFailureRetriesAFileBackedCaptureWithoutDuplicatingIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        let storeIdentity = ObjectIdentifier(store)
        let notificationCount = NotificationCount()
        let notificationToken = NotificationCenter.default.addObserver(
            forName: .yankLocalStoreDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let object = notification.object as AnyObject?,
                  ObjectIdentifier(object) == storeIdentity else { return }
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(notificationToken) }
        let largeText = String(repeating: "snapshot retry ", count: 4_001)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        let failed = await store.captureForegroundText(
            largeText,
            pasteboardGeneration: 61,
            hasRichContent: true
        )

        #expect(failed == .retryableFailure)
        #expect(store.items.count == 1)
        #expect(notificationCount.value == 0)
        let pendingItem = try #require(store.items.first)
        let pendingFilename = try #require(pendingItem.textFilename)
        #expect(pendingItem.hasRichContent)
        let pendingBlobCount = try FileManager.default.contentsOfDirectory(
            at: fixture.context.blobsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == SyncBlobKind.text.allowedExtension }.count
        #expect(pendingBlobCount == 1)

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        let retried = await store.captureForegroundText(
            largeText,
            pasteboardGeneration: 61,
            hasRichContent: true
        )

        #expect(retried == .durable)
        #expect(store.items.count == 1)
        #expect(notificationCount.value == 1)
        #expect(store.items.first?.id == pendingItem.id)
        #expect(store.items.first?.textFilename == pendingFilename)
        #expect(store.items.first?.hasRichContent == true)
        let finalBlobCount = try FileManager.default.contentsOfDirectory(
            at: fixture.context.blobsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == SyncBlobKind.text.allowedExtension }.count
        #expect(finalBlobCount == 1)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.map(\.id) == [pendingItem.id])
        #expect(snapshot.items.first?.hasRichContent == true)
    }

    @Test func foregroundDuplicateRefreshAdvancesOnlyAfterItsSnapshotIsDurable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let existing = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "duplicate retry",
            isBookmarked: true
        )
        try writeHistory([existing], in: fixture)
        let store = ClipStore(context: fixture.context)
        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        let failed = await store.captureForegroundText(
            "duplicate retry",
            pasteboardGeneration: 62,
            hasRichContent: false
        )

        #expect(failed == .retryableFailure)
        #expect(store.items.count == 1)
        let failedRefresh = try #require(store.items.first)
        #expect(failedRefresh.id == existing.id)
        #expect(failedRefresh.timestamp > existing.timestamp)
        #expect(failedRefresh.isBookmarked)

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        let retried = await store.captureForegroundText(
            "duplicate retry",
            pasteboardGeneration: 62,
            hasRichContent: false
        )

        #expect(retried == .durable)
        #expect(store.items.count == 1)
        #expect(store.items.first?.id == existing.id)
        #expect(store.items.first?.timestamp == failedRefresh.timestamp)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items == store.items)
    }

    @Test func foregroundRetryDoesNotAcknowledgeASameIDRemoteReplacement() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let existing = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "pending clipboard value",
            isBookmarked: true
        )
        try writeHistory([existing], in: fixture)
        let store = ClipStore(context: fixture.context)
        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        let failed = await store.captureForegroundText(
            "pending clipboard value",
            pasteboardGeneration: 64,
            hasRichContent: false
        )
        #expect(failed == .retryableFailure)

        let remoteReplacement = ClipboardItem(
            id: existing.id,
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 200),
            textContent: "newer remote value",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        #expect(throws: (any Error).self) {
            try store.applyReconciledDurably([remoteReplacement])
        }

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        let retried = await store.captureForegroundText(
            "pending clipboard value",
            pasteboardGeneration: 64,
            hasRichContent: false
        )

        #expect(retried == .durable)
        #expect(store.items.count == 2)
        #expect(store.items.contains { $0.id == existing.id && $0.textContent == "newer remote value" })
        #expect(store.items.contains {
            $0.id != existing.id && $0.textContent == "pending clipboard value"
        })
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items == store.items)
    }

    @Test func foregroundHistoryLimitDefersEvictedBlobDeletionUntilDurability() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.context.defaults.set(1, forKey: SettingsKeys.historyLimit)
        let oldFilename = UUID().uuidString + "." + SyncBlobKind.text.allowedExtension
        let oldBlobURL = fixture.context.blobsURL.appendingPathComponent(oldFilename)
        try FileManager.default.createDirectory(
            at: fixture.context.blobsURL,
            withIntermediateDirectories: true
        )
        try Data("old full text".utf8).write(to: oldBlobURL)
        let oldItem = ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "old preview",
            textFilename: oldFilename,
            originalSizeBytes: 60_000
        )
        try writeHistory([oldItem], in: fixture)
        let store = ClipStore(context: fixture.context)
        try FileManager.default.removeItem(at: fixture.context.historyURL)
        try FileManager.default.createDirectory(
            at: fixture.context.historyURL,
            withIntermediateDirectories: false
        )

        let largeText = String(repeating: "new capped capture ", count: 3_001)
        let failed = await store.captureForegroundText(
            largeText,
            pasteboardGeneration: 63,
            hasRichContent: false
        )

        #expect(failed == .retryableFailure)
        #expect(store.items.count == 1)
        #expect(store.items.first?.id != oldItem.id)
        #expect(FileManager.default.fileExists(atPath: oldBlobURL.path))

        try FileManager.default.removeItem(at: fixture.context.historyURL)
        let retried = await store.captureForegroundText(
            largeText,
            pasteboardGeneration: 63,
            hasRichContent: false
        )

        #expect(retried == .durable)
        #expect(store.items.count == 1)
        #expect(!FileManager.default.fileExists(atPath: oldBlobURL.path))
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

    private func writeHistory(_ items: [ClipboardItem], in fixture: Fixture) throws {
        try JSONEncoder().encode(items).write(to: fixture.context.historyURL, options: .atomic)
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

private final class NotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
