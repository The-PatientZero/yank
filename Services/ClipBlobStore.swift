import Foundation
import AppKit

private enum ClipboardStoreFileSecurity {
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600
    static let fileProtection: FileProtectionType = .complete
    static let writeOptions: Data.WritingOptions = .atomic

    static var directoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: directoryPermissions]
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: writeOptions)
        try applyPrivateFileAttributes(to: url)
    }

    static func writeText(_ text: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try write(Data(text.utf8), to: url)
        }.value
    }

    static func applyPrivateFileAttributes(to url: URL) throws {
        try PrivateFileAttributes.apply(to: url, permissions: filePermissions, protection: fileProtection)
    }

    static func applyPrivateDirectoryAttributes(to url: URL) throws {
        try PrivateFileAttributes.apply(to: url, permissions: directoryPermissions, protection: fileProtection)
    }

    static func secureExistingFiles(in directories: [URL]) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey]
            for directory in directories {
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    do {
                        try applyPrivateFileAttributes(to: url)
                    } catch {
                        // Privacy-relevant: surface a failure to lock down an existing clip file
                        // rather than letting it pass silently.
                        Log.store.warning("Failed to secure existing clip file: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

/// Owns the on-disk blob layout for `ClipboardStore`: the storage directory tree
/// (texts / images / rich), its private-file/data-protection attributes, and the
/// read/write/delete of blob files within it. The store delegates every filesystem
/// concern here and keeps only in-memory history, persistence, and sync coordination.
@MainActor
final class ClipBlobStore {
    private let fileManager = FileManager.default
    private let storageDirectoryOverride: URL?

    /// Security parameters for the history snapshot writer and synced-blob writes, which
    /// live on `ClipboardStore` but must use the same permissions/protection as blob files.
    nonisolated static var writeOptions: Data.WritingOptions { ClipboardStoreFileSecurity.writeOptions }
    nonisolated static var filePermissions: Int { ClipboardStoreFileSecurity.filePermissions }
    nonisolated static var fileProtection: FileProtectionType { ClipboardStoreFileSecurity.fileProtection }

    init(storageDirectoryOverride: URL?) {
        self.storageDirectoryOverride = storageDirectoryOverride
    }

    // MARK: - Directory layout

    var storageDirectory: URL {
        if let storageDirectoryOverride { return storageDirectoryOverride }
        // Application Support effectively always exists for a Mac app, but never trap the
        // app at launch if the lookup is empty (sandbox/odd-volume edge) — fail soft to tmp.
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Yank", isDirectory: true)
    }

    private var imagesDirectory: URL {
        storageDirectory.appendingPathComponent("images", isDirectory: true)
    }

    private var textsDirectory: URL {
        storageDirectory.appendingPathComponent("texts", isDirectory: true)
    }

    private var richDirectory: URL {
        storageDirectory.appendingPathComponent("rich", isDirectory: true)
    }

    /// Create the storage tree, apply private attributes, secure any pre-existing files, and
    /// exclude the subtree from backups. Returns `true` when every directory was created;
    /// `false` (with a logged error per failure) means history cannot be persisted this
    /// session, so the caller surfaces it via `storageUnavailable`.
    @discardableResult
    func ensureDirectoriesExist() -> Bool {
        // Failing to create the storage tree means history cannot be persisted this
        // session — captures would be silently lost on quit. Surface it explicitly via
        // `storageUnavailable` and log with context instead of swallowing.
        let directories = [storageDirectory, imagesDirectory, textsDirectory, richDirectory]
        var succeeded = true
        for directory in directories {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: ClipboardStoreFileSecurity.directoryAttributes
                )
                try ClipboardStoreFileSecurity.applyPrivateDirectoryAttributes(to: directory)
            } catch {
                succeeded = false
                Log.store.error(
                    "Failed to create storage directory \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
        ClipboardStoreFileSecurity.secureExistingFiles(in: directories)
        // Keep clip history (which can hold secrets) out of Time Machine / iCloud backups;
        // excluding the parent covers the whole subtree. CloudKit sync is the intended
        // cross-device/restore path for clips the user wants to keep.
        excludeFromBackup(storageDirectory)
        return succeeded
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Blob URL resolution

    func blobURL(for item: ClipboardItem) -> URL? {
        if let filename = item.imageFilename {
            return SyncBlobPolicy.containedURL(directory: imagesDirectory, filename: filename, kind: .image)
        }
        if let filename = item.textFilename {
            return SyncBlobPolicy.containedURL(directory: textsDirectory, filename: filename, kind: .text)
        }
        return nil
    }

    func blobURL(for reference: ClipboardBlobReference) -> URL? {
        switch reference.kind {
        case .image:
            SyncBlobPolicy.containedURL(directory: imagesDirectory, filename: reference.filename, kind: .image)
        case .text:
            SyncBlobPolicy.containedURL(directory: textsDirectory, filename: reference.filename, kind: .text)
        case .rich:
            SyncBlobPolicy.containedURL(directory: richDirectory, filename: reference.filename, kind: .rich)
        }
    }

    func richArchiveURL(for item: ClipboardItem) -> URL? {
        guard let filename = item.richFilename else { return nil }
        return SyncBlobPolicy.containedURL(directory: richDirectory, filename: filename, kind: .rich)
    }

    func textURL(filename: String) -> URL? {
        SyncBlobPolicy.containedURL(directory: textsDirectory, filename: filename, kind: .text)
    }

    func imageURL(filename: String) -> URL? {
        SyncBlobPolicy.containedURL(directory: imagesDirectory, filename: filename, kind: .image)
    }

    func directory(for kind: SyncBlobKind) -> URL {
        switch kind {
        case .image:
            imagesDirectory
        case .text:
            textsDirectory
        case .rich:
            richDirectory
        }
    }

    // MARK: - Blob writes

    func saveImage(_ data: Data) -> String? {
        let filename = UUID().uuidString + ".png"
        let url = imagesDirectory.appendingPathComponent(filename)

        do {
            try ClipboardStoreFileSecurity.write(data, to: url)
            return filename
        } catch {
            Log.store.error("Failed to save image: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist a full pasteboard archive (binary plist) and return its filename (#11).
    func saveRichArchive(_ archive: PasteboardArchive) -> String? {
        let filename = UUID().uuidString + ".plist"
        let url = richDirectory.appendingPathComponent(filename)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try ClipboardStoreFileSecurity.write(encoder.encode(archive), to: url)
            return filename
        } catch {
            Log.store.error("Failed to save rich archive: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save large text to a file and return the filename
    func saveText(_ text: String) -> String? {
        let filename = UUID().uuidString + ".txt"
        let url = textsDirectory.appendingPathComponent(filename)

        do {
            try ClipboardStoreFileSecurity.write(Data(text.utf8), to: url)
            return filename
        } catch {
            Log.store.error("Failed to save text file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save large text off the main actor and return the filename. Used by clipboard
    /// capture, where a multi-MB write should never stall the menu-bar UI.
    func saveTextAsync(_ text: String) async -> String? {
        let filename = UUID().uuidString + ".txt"
        let url = textsDirectory.appendingPathComponent(filename)

        do {
            try await ClipboardStoreFileSecurity.writeText(text, to: url)
            return filename
        } catch {
            Log.store.error("Failed to save text file: \(error.localizedDescription)")
            return nil
        }
    }

    func writeSyncedBlob(_ data: Data, reference: SyncBlobReference) async throws {
        let directory = directory(for: reference.kind)
        guard let url = reference.containedURL(in: directory) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        do {
            try await SyncBlobStorage.write(
                data,
                to: url,
                maxBytes: reference.maximumBytes,
                writeOptions: ClipboardStoreFileSecurity.writeOptions,
                filePermissions: ClipboardStoreFileSecurity.filePermissions,
                fileProtection: ClipboardStoreFileSecurity.fileProtection
            )
        } catch {
            Log.store.error("Failed to write synced blob \(reference.filename, privacy: .public): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Blob deletion

    func deleteBlobReferences(_ references: [ClipboardBlobReference]) {
        for reference in references {
            guard let url = blobURL(for: reference) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func deleteSyncedBlob(_ reference: SyncBlobReference) {
        let directory = directory(for: reference.kind)
        guard let url = reference.containedURL(in: directory) else { return }
        try? fileManager.removeItem(at: url)
    }

    func blobURL(for reference: SyncBlobReference) -> URL? {
        let directory = directory(for: reference.kind)
        return reference.containedURL(in: directory)
    }

    // MARK: - Blob reads

    func fileSize(at url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    func copyImageBlob(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}
