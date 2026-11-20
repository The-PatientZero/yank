import Foundation
import Testing
@testable import Yank

@Suite("Launch orphan blob sweep")
@MainActor
struct ClipboardStoreOrphanBlobSweepTests {
    @Test("An orphaned blob is removed while referenced text, image, and rich files survive")
    func sweepRemovesOrphansAndKeepsReferencedFiles() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankOrphanBlobSweepTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)

        let keptTextFilename = UUID().uuidString + ".txt"
        let keptRichFilename = UUID().uuidString + ".plist"
        let keptImageFilename = UUID().uuidString + ".png"
        let orphanTextFilename = UUID().uuidString + ".txt"
        let orphanImageFilename = UUID().uuidString + ".png"
        let orphanRichFilename = UUID().uuidString + ".plist"

        write("kept", named: keptTextFilename, in: store.blobStore.directory(for: .text))
        write("kept", named: keptRichFilename, in: store.blobStore.directory(for: .rich))
        write("kept", named: keptImageFilename, in: store.blobStore.directory(for: .image))
        write("orphan", named: orphanTextFilename, in: store.blobStore.directory(for: .text))
        write("orphan", named: orphanImageFilename, in: store.blobStore.directory(for: .image))
        write("orphan", named: orphanRichFilename, in: store.blobStore.directory(for: .rich))

        store.add(ClipboardItem(type: .text, textFilename: keptTextFilename, richFilename: keptRichFilename))
        store.add(ClipboardItem(type: .image, imageFilename: keptImageFilename))
        store.flushPendingWrites()

        // Reopen against the same directory to simulate a relaunch, which is what actually
        // runs the sweep.
        let reloaded = ClipboardStore(settings: .unbounded, storageDirectory: directory)

        let fileManager = FileManager.default
        let textDirectory = reloaded.blobStore.directory(for: .text)
        let imageDirectory = reloaded.blobStore.directory(for: .image)
        let richDirectory = reloaded.blobStore.directory(for: .rich)

        #expect(reloaded.items.count == 2)
        #expect(fileManager.fileExists(atPath: textDirectory.appendingPathComponent(keptTextFilename).path))
        #expect(fileManager.fileExists(atPath: imageDirectory.appendingPathComponent(keptImageFilename).path))
        #expect(fileManager.fileExists(atPath: richDirectory.appendingPathComponent(keptRichFilename).path))
        #expect(!fileManager.fileExists(atPath: textDirectory.appendingPathComponent(orphanTextFilename).path))
        #expect(!fileManager.fileExists(atPath: imageDirectory.appendingPathComponent(orphanImageFilename).path))
        #expect(!fileManager.fileExists(atPath: richDirectory.appendingPathComponent(orphanRichFilename).path))
    }

    @Test("A directory that can't be listed skips the sweep instead of guessing")
    func unreadableDirectorySkipsSweep() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankOrphanBlobSweepUnreadableTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobStore = ClipBlobStore(storageDirectoryOverride: directory)
        blobStore.ensureDirectoriesExist()
        // Removing a directory after it's been created is a portable stand-in for
        // "unreadable" (odd volume, permissions) that doesn't depend on POSIX mode bits a
        // sandboxed test runner may not honor.
        try? FileManager.default.removeItem(at: blobStore.directory(for: .rich))

        #expect(blobStore.allBlobReferences() == nil)
    }

    private func write(_ content: String, named filename: String, in directory: URL) {
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(filename).path,
            contents: Data(content.utf8)
        )
    }
}
