import Foundation
import Testing
@testable import Yank

/// `ClipBlobStore` is where the privacy guarantees for clip files actually land: the
/// directory tree, its POSIX modes, and blob containment. Those are filesystem effects, so
/// they are asserted against a real temporary tree rather than a stub.
@Suite("Clip blob store", .serialized)
@MainActor
struct ClipBlobStoreTests {
    private func makeStore() throws -> (store: ClipBlobStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBlobStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (ClipBlobStore(storageDirectoryOverride: root), root)
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Directory tree

    @Test("The storage tree is created private and reported healthy")
    func storageTreeIsPrivate() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.ensureDirectoriesExist())

        for directory in [root]
            + ["images", "texts", "rich"].map({ root.appendingPathComponent($0) }) {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            // 0o700: clip history can hold secrets, so no group or other access.
            #expect(try mode(of: directory) == 0o700, "\(directory.lastPathComponent) is not 0o700")
        }
    }

    @Test("An unusable storage location is reported instead of swallowed")
    func unusableStorageLocationIsReported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBlobStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file where the storage directory belongs: creation cannot succeed, and
        // the caller must learn that history is not persistable this session.
        try Data("occupied".utf8).write(to: root)

        let store = ClipBlobStore(storageDirectoryOverride: root)

        #expect(store.ensureDirectoriesExist() == false)
    }

    @Test("The storage tree is excluded from backups")
    func storageTreeIsExcludedFromBackup() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())

        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])

        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - Writes

    @Test("An image blob is written owner-only under images/")
    func imageBlobIsPrivate() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())

        let filename = try #require(store.saveImage(Data("png-bytes".utf8)))

        #expect(filename.hasSuffix(".png"))
        #expect(UUID(uuidString: String(filename.dropLast(4))) != nil)
        let url = root.appendingPathComponent("images").appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try mode(of: url) == 0o600)
        #expect(store.fileSize(at: url) == Data("png-bytes".utf8).count)
    }

    @Test("A text blob is written owner-only under texts/")
    func textBlobIsPrivate() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())

        let filename = try #require(await store.saveTextAsync("secret clipboard body"))

        #expect(filename.hasSuffix(".txt"))
        let url = root.appendingPathComponent("texts").appendingPathComponent(filename)
        #expect(try mode(of: url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "secret clipboard body")
    }

    @Test("A rich archive is written owner-only under rich/")
    func richArchiveIsPrivate() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())
        let archive = PasteboardArchive(representations: [
            .init(uti: "public.utf8-plain-text", data: Data("hello".utf8))
        ])

        let filename = try #require(store.saveRichArchive(archive))

        #expect(filename.hasSuffix(".plist"))
        let url = root.appendingPathComponent("rich").appendingPathComponent(filename)
        #expect(try mode(of: url) == 0o600)
    }

    @Test("A write into a tree that was never created fails without trapping")
    func writeWithoutTreeFails() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.saveImage(Data("png-bytes".utf8)) == nil)
    }

    // MARK: - Deletion and containment

    @Test("Deleting a blob reference removes the file")
    func deletingBlobReferenceRemovesFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())
        let filename = try #require(store.saveImage(Data("png-bytes".utf8)))
        let url = root.appendingPathComponent("images").appendingPathComponent(filename)

        store.deleteBlobReferences([ClipboardBlobReference(kind: .image, filename: filename)])

        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("A reference that would escape its directory resolves to no URL")
    func escapingReferenceIsRefused() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())

        for filename in [
            "../texts/escape.png",
            "/etc/passwd.png",
            "..%2Fescape.png",
            "not-a-uuid.png",
            "\(UUID().uuidString).txt"   // right shape, wrong kind for the images directory
        ] {
            #expect(
                store.blobURL(for: ClipboardBlobReference(kind: .image, filename: filename)) == nil,
                "\(filename) resolved to a URL"
            )
        }
    }

    @Test("A well-formed reference resolves inside its own directory")
    func wellFormedReferenceResolvesInsideDirectory() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.ensureDirectoriesExist())
        let filename = "\(UUID().uuidString).txt"

        let url = try #require(
            store.blobURL(for: ClipboardBlobReference(kind: .text, filename: filename))
        )

        #expect(url.deletingLastPathComponent().lastPathComponent == "texts")
        #expect(url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
    }
}
