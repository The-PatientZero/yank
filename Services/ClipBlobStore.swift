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

enum ClipboardCapturePrimaryBlob: Equatable, Sendable {
    case text(String)
    case image(Data)

    var kind: SyncBlobKind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }
}

struct PersistedClipboardCaptureBlobs: Sendable {
    let primaryKind: SyncBlobKind?
    let primaryFilename: String?
    let richFilename: String?

    var references: [ClipboardBlobReference] {
        var result: [ClipboardBlobReference] = []
        if let primaryKind, let primaryFilename {
            let referenceKind: ClipboardBlobReference.Kind
            switch primaryKind {
            case .image:
                referenceKind = .image
            case .text:
                referenceKind = .text
            case .rich:
                assertionFailure("A rich archive cannot be a primary capture blob")
                referenceKind = .rich
            }
            result.append(ClipboardBlobReference(
                kind: referenceKind,
                filename: primaryFilename
            ))
        }
        if let richFilename {
            result.append(ClipboardBlobReference(kind: .rich, filename: richFilename))
        }
        return result
    }
}

enum ClipboardCaptureBlobPersistence {
    struct Directories: Sendable {
        let images: URL
        let texts: URL
        let rich: URL
    }

    nonisolated static func persist(
        primary: ClipboardCapturePrimaryBlob?,
        richArchive: PasteboardArchive?,
        directories: Directories,
        richMaximumBytes: Int = SyncBlobKind.rich.maximumBytes
    ) -> PersistedClipboardCaptureBlobs? {
        let primaryFilename: String?
        if let primary {
            let data: Data
            switch primary {
            case .text(let text):
                data = Data(text.utf8)
            case .image(let imageData):
                data = imageData
            }
            guard !data.isEmpty, data.count <= primary.kind.maximumBytes else {
                Log.store.error("Rejected oversized or empty \(String(describing: primary.kind)) capture blob")
                return nil
            }

            let filename = UUID().uuidString + ".\(primary.kind.allowedExtension)"
            let directory = primary.kind == .image ? directories.images : directories.texts
            let url = directory.appendingPathComponent(filename)
            do {
                try ClipboardStoreFileSecurity.write(data, to: url)
                primaryFilename = filename
            } catch {
                try? FileManager.default.removeItem(at: url)
                Log.store.error("Failed to save capture blob: \(error.localizedDescription)")
                return nil
            }
        } else {
            primaryFilename = nil
        }

        var richFilename: String?
        if let richArchive, !richArchive.isEmpty {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let encoded = try encoder.encode(richArchive)
                guard encoded.count <= richMaximumBytes else {
                    Log.store.error("Rejected oversized encoded rich capture archive")
                    return PersistedClipboardCaptureBlobs(
                        primaryKind: primary?.kind,
                        primaryFilename: primaryFilename,
                        richFilename: nil
                    )
                }
                let filename = UUID().uuidString + ".\(SyncBlobKind.rich.allowedExtension)"
                let url = directories.rich.appendingPathComponent(filename)
                do {
                    try ClipboardStoreFileSecurity.write(encoded, to: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                richFilename = filename
            } catch {
                Log.store.error("Failed to save rich archive: \(error.localizedDescription)")
            }
        }

        return PersistedClipboardCaptureBlobs(
            primaryKind: primary?.kind,
            primaryFilename: primaryFilename,
            richFilename: richFilename
        )
    }

    nonisolated static func discard(
        _ persisted: PersistedClipboardCaptureBlobs,
        directories: Directories
    ) {
        let fileManager = FileManager.default
        for reference in persisted.references {
            let directory: URL
            switch reference.kind {
            case .image:
                directory = directories.images
            case .text:
                directory = directories.texts
            case .rich:
                directory = directories.rich
            }
            try? fileManager.removeItem(at: directory.appendingPathComponent(reference.filename))
        }
    }
}

/// Owns the on-disk blob layout for `ClipboardStore`: directory tree (texts / images / rich),
/// private-file/data-protection attributes, and blob read/write/delete. `ClipboardStore` keeps
/// only in-memory history, persistence, and sync coordination — filesystem concerns live here.
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

    /// Creates the storage tree, applies private attributes, secures pre-existing files, and
    /// excludes the subtree from backups. Returns `false` (each failure already logged) when
    /// history can't be persisted this session — the caller surfaces that via `storageUnavailable`.
    @discardableResult
    func ensureDirectoriesExist() -> Bool {
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

    func persistCaptureBlobs(
        primary: ClipboardCapturePrimaryBlob?,
        richArchive: PasteboardArchive?
    ) async -> PersistedClipboardCaptureBlobs? {
        let directories = ClipboardCaptureBlobPersistence.Directories(
            images: imagesDirectory,
            texts: textsDirectory,
            rich: richDirectory
        )
        return await Task.detached(priority: .utility) {
            ClipboardCaptureBlobPersistence.persist(
                primary: primary,
                richArchive: richArchive,
                directories: directories
            )
        }.value
    }

    func discardCaptureBlobs(_ persisted: PersistedClipboardCaptureBlobs) async {
        let directories = ClipboardCaptureBlobPersistence.Directories(
            images: imagesDirectory,
            texts: textsDirectory,
            rich: richDirectory
        )
        await Task.detached(priority: .utility) {
            ClipboardCaptureBlobPersistence.discard(persisted, directories: directories)
        }.value
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

    /// Every blob file actually present across the owned directories, or `nil` if any
    /// directory listing failed (permissions, odd volume) — callers should skip a sweep
    /// entirely rather than delete from a partial listing.
    func allBlobReferences() -> Set<ClipboardBlobReference>? {
        var result: Set<ClipboardBlobReference> = []
        for kind in [SyncBlobKind.image, .text, .rich] {
            guard let filenames = try? fileManager.contentsOfDirectory(atPath: directory(for: kind).path) else {
                return nil
            }
            let referenceKind: ClipboardBlobReference.Kind
            switch kind {
            case .image: referenceKind = .image
            case .text: referenceKind = .text
            case .rich: referenceKind = .rich
            }
            for filename in filenames {
                result.insert(ClipboardBlobReference(kind: referenceKind, filename: filename))
            }
        }
        return result
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
