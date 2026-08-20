import Foundation
import Testing
@testable import YankiOS

@Suite("iOS launch orphan blob sweep")
@MainActor
struct IOSClipStoreOrphanBlobSweepTests {
    @Test("An unreferenced blob is removed at launch while a referenced one survives")
    func orphanBlobIsRemovedWhileReferencedBlobSurvives() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        // First launch: capture one image so its blob is genuinely referenced by history.
        let firstStore = ClipStore(context: fixture.context)
        let captured = await firstStore.captureImage(pngData: Data([0x01]))
        #expect(captured)
        try firstStore.flushPendingWrites()
        let referencedFilename = try #require(firstStore.items.first?.imageFilename)
        let referencedURL = fixture.context.blobsURL.appendingPathComponent(referencedFilename)
        #expect(FileManager.default.fileExists(atPath: referencedURL.path))

        // A staged write that never got promoted or cleaned up — e.g. a crash between
        // `writeRemoteBlobStaged`'s write and its rename/delete. Nothing will ever reference it.
        let orphanURL = fixture.context.blobsURL.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x02]).write(to: orphanURL)

        // Second launch: the sweep runs against the snapshot `firstStore` just persisted.
        _ = ClipStore(context: fixture.context)

        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: referencedURL.path))
    }

    @Test("The sweep never touches the share capture inbox")
    func sweepLeavesShareCaptureInboxAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.context.shareInbox.enqueue(
            text: "pending share",
            sourceApp: "Share",
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        _ = ClipStore(context: fixture.context)

        let pending = try fixture.context.shareInbox.pendingEntries()
        #expect(pending.contains { $0.id == entry.id })
    }

    @Test("An unreadable blobs directory is a silent no-op")
    func unreadableBlobsDirectoryIsSilentNoOp() {
        let notADirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSClipStoreOrphanBlobSweepTests-\(UUID().uuidString)")
        // A regular file where a directory is expected — `contentsOfDirectory` fails on it.
        FileManager.default.createFile(atPath: notADirectory.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: notADirectory) }

        let blobStore = IOSClipBlobStore(directory: notADirectory)

        #expect(blobStore.sweepOrphans(referenced: []) == 0)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSClipStoreOrphanBlobSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "IOSClipStoreOrphanBlobSweepTests.\(UUID().uuidString)"
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
