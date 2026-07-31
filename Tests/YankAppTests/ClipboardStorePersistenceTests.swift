import Foundation
import Testing
@testable import Yank

@Suite("Clipboard Store Persistence")
@MainActor
struct ClipboardStorePersistenceTests {
    @Test("Exact text refreshes the newest match without merging older duplicates")
    func exactTextRefreshesNewestExistingMatchOnly() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankClipboardStoreDedupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let olderID = UUID()
        let newerID = UUID()
        let unrelatedID = UUID()
        let older = ClipboardItem(
            id: olderID,
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "duplicate"
        )
        let newer = ClipboardItem(
            id: newerID,
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 200),
            sourceApp: "Old Source",
            textContent: "duplicate",
            isBookmarked: true,
            tags: ["keep"]
        )
        let unrelated = ClipboardItem(
            id: unrelatedID,
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 300),
            textContent: "unrelated"
        )
        store.items = [unrelated, older, newer]
        let incoming = ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 400),
            sourceApp: "New Source",
            textContent: "duplicate",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 450),
            deviceOrigin: "new-device"
        )

        store.add(incoming)

        #expect(store.items.count == 3)
        #expect(store.items[0].id == newerID)
        #expect(store.items[0].timestamp == incoming.timestamp)
        #expect(store.items[0].sourceApp == "New Source")
        #expect(store.items[0].modifiedAt == incoming.modifiedAt)
        #expect(store.items[0].deviceOrigin == "new-device")
        #expect(store.items[0].isBookmarked)
        #expect(store.items[0].tags == ["keep"])
        #expect(store.items.contains { $0.id == olderID })
        #expect(store.items.contains { $0.id == unrelatedID })
    }

    @Test("Refreshing an already-first duplicate is persisted")
    func frontDuplicateRefreshPersists() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankClipboardStoreFrontDedupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let existingID = UUID()
        store.items = [
            ClipboardItem(
                id: existingID,
                type: .text,
                timestamp: Date(timeIntervalSinceReferenceDate: 100),
                sourceApp: "Old Source",
                textContent: "same",
                isPinned: true
            )
        ]
        let incoming = ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 500),
            sourceApp: "New Source",
            textContent: "same",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 550),
            deviceOrigin: "new-device"
        )

        store.add(incoming)
        store.flushPendingWrites()
        let reloaded = ClipboardStore(settings: .unbounded, storageDirectory: directory)

        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].id == existingID)
        #expect(reloaded.items[0].timestamp == incoming.timestamp)
        #expect(reloaded.items[0].sourceApp == "New Source")
        #expect(reloaded.items[0].isPinned)
    }

    @Test("File-backed capture does not collapse into an inline preview duplicate")
    func fileBackedCapturePersistsBeforeInsertionWithoutFalseDedup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankFileBackedCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        store.add(.text("shared preview", sourceApp: "Existing"))
        let fullText = "shared preview with the complete file-backed payload"
        let draft = ClipboardItem(
            type: .text,
            sourceApp: "New",
            textContent: "shared preview",
            originalSizeBytes: fullText.utf8.count,
            searchIndex: "shared preview complete"
        )

        await store.addCaptured(
            draft,
            primaryBlob: .text(fullText),
            richArchive: nil
        )

        #expect(store.items.count == 2)
        let captured = try #require(store.items.first)
        let filename = try #require(captured.textFilename)
        #expect(captured.id == draft.id)
        #expect(
            try String(
                contentsOf: directory
                    .appendingPathComponent("texts", isDirectory: true)
                    .appendingPathComponent(filename),
                encoding: .utf8
            ) == fullText
        )
    }

    @Test("Cancellation after capture blob persistence leaves no orphan files")
    func cancelledCaptureRemovesPersistedBlobs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankCancelledCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        var draft = ClipboardItem(type: .image, sourceApp: "Test")
        draft.hasRichContent = true
        let archive = PasteboardArchive(representations: [
            .init(uti: "public.rtf", data: Data("rich".utf8))
        ])

        let task = Task { @MainActor in
            await store.addCaptured(
                draft,
                primaryBlob: .image(Data([0x89, 0x50, 0x4E, 0x47])),
                richArchive: archive
            )
        }
        task.cancel()
        await task.value

        #expect(store.items.isEmpty)
        let images = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("images", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let rich = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("rich", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(images.isEmpty)
        #expect(rich.isEmpty)
    }

    @Test("Corrupt existing history disables saves instead of overwriting")
    func corruptExistingHistoryDisablesSavesInsteadOfOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankClipboardStorePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyURL = directory.appendingPathComponent("history.json")
        let corruptData = Data("not history json".utf8)
        try corruptData.write(to: historyURL)

        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)

        #expect(store.storageUnavailable)
        store.add(.text("new clip", sourceApp: "Test"))
        store.flushPendingWrites()

        #expect(try Data(contentsOf: historyURL) == corruptData)
    }

    @Test("Reconcile keeps blobs until the replacement snapshot is durable")
    func reconcileKeepsBlobsUntilReplacementSnapshotIsDurable() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("YankReconcilePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let filename = "\(UUID().uuidString).png"
        let blobURL = directory.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(filename)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: blobURL)
        store.add(.image(filename: filename, sourceApp: "Test"))
        store.flushPendingWrites()

        let historyURL = directory.appendingPathComponent("history.json")
        try fileManager.removeItem(at: historyURL)
        try fileManager.createDirectory(at: historyURL, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try store.applyReconciledDurably([])
        }
        #expect(fileManager.fileExists(atPath: blobURL.path))

        try fileManager.removeItem(at: historyURL)
        try store.applyReconciledDurably([])
        #expect(!fileManager.fileExists(atPath: blobURL.path))
    }

    @Test("Reconcile keeps a deferred blob that becomes referenced again")
    func reconcileKeepsDeferredBlobWhenReferencedAgain() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("YankReconcileReintroductionTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        let filename = "\(UUID().uuidString).png"
        let item = ClipboardItem.image(filename: filename, sourceApp: "Test")
        let blobURL = directory.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(filename)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: blobURL)
        store.add(item)
        store.flushPendingWrites()

        let historyURL = directory.appendingPathComponent("history.json")
        try fileManager.removeItem(at: historyURL)
        try fileManager.createDirectory(at: historyURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.applyReconciledDurably([])
        }

        try fileManager.removeItem(at: historyURL)
        try store.applyReconciledDurably([item])

        #expect(fileManager.fileExists(atPath: blobURL.path))
    }
}

@Suite("Capture Feedback Policy")
struct CaptureFeedbackPolicyTests {
    @Test("Fresh captures remain eligible for audible confirmation")
    func freshCaptureAllowsSound() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = observedAt.addingTimeInterval(CaptureFeedbackPolicy.maximumAudibleLatency)

        #expect(CaptureFeedbackPolicy.allowsSound(observedAt: observedAt, now: now))
    }

    @Test("Stale captures suppress audible confirmation")
    func staleCaptureSuppressesSound() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = observedAt.addingTimeInterval(
            CaptureFeedbackPolicy.maximumAudibleLatency + 0.001
        )

        #expect(!CaptureFeedbackPolicy.allowsSound(observedAt: observedAt, now: now))
    }

    @Test("Clock correction does not make a fresh capture silent")
    func futureObservationAllowsSound() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let observedAt = now.addingTimeInterval(1)

        #expect(CaptureFeedbackPolicy.allowsSound(observedAt: observedAt, now: now))
    }
}
