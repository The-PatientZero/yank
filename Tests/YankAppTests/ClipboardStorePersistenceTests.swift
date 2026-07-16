import Foundation
import Testing
@testable import Yank

@Suite("Clipboard Store Persistence")
@MainActor
struct ClipboardStorePersistenceTests {
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
