import Foundation

/// Owns the iOS blob layout inside the App Group container: filename validation, containment,
/// and every read/write/delete of a clip's backing file. `ClipStore` delegates its filesystem
/// concerns here and keeps in-memory history, persistence, and sync coordination — the same
/// split the macOS store already uses with `ClipBlobStore`.
///
/// A nil directory means the App Group could not be resolved. Every operation then fails closed
/// rather than silently writing into a process-local container.
@MainActor
struct IOSClipBlobStore {
    private let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    var isAvailable: Bool { directory != nil }

    // MARK: - Resolution

    func url(for item: ClipboardItem) -> URL? {
        guard let directory else { return nil }
        if let filename = item.imageFilename {
            return SyncBlobPolicy.containedURL(directory: directory, filename: filename, kind: .image)
        }
        if let filename = item.textFilename {
            return SyncBlobPolicy.containedURL(directory: directory, filename: filename, kind: .text)
        }
        return nil
    }

    func url(for reference: SyncBlobReference) -> URL? {
        guard let directory else { return nil }
        return reference.containedURL(in: directory)
    }

    // MARK: - Writes

    /// Returns the stored filename, or nil when the container is missing, the name would
    /// escape the blobs directory, or the write failed.
    func saveText(_ text: String, filename: String? = nil) async -> String? {
        await save(
            Data(text.utf8),
            kind: .text,
            filename: filename,
            maxBytes: SyncBlobKind.text.maximumBytes,
            label: "text"
        )
    }

    func saveImage(_ data: Data, filename: String? = nil) async -> String? {
        await save(data, kind: .image, filename: filename, maxBytes: nil, label: "image")
    }

    private func save(
        _ data: Data,
        kind: SyncBlobKind,
        filename: String?,
        maxBytes: Int?,
        label: String
    ) async -> String? {
        let filename = filename ?? UUID().uuidString + "." + kind.allowedExtension
        guard let directory,
              let url = SyncBlobPolicy.containedURL(
                directory: directory,
                filename: filename,
                kind: kind
              ) else {
            return nil
        }
        do {
            if let maxBytes {
                try await SyncBlobStorage.write(data, to: url, maxBytes: maxBytes)
            } else {
                try await SyncBlobStorage.write(data, to: url)
            }
            return filename
        } catch {
            clipStoreLog.error("Failed to save iOS \(label) blob: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sync's blob write. Throws rather than returning nil: a failed synced blob must hold the
    /// remote checkpoint back, not be silently skipped.
    func write(_ data: Data, reference: SyncBlobReference) async throws {
        guard let directory, let url = reference.containedURL(in: directory) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        try await SyncBlobStorage.write(data, to: url, maxBytes: reference.maximumBytes)
    }

    // MARK: - Deletion

    func delete(_ reference: SyncBlobReference) {
        guard let directory, let url = reference.containedURL(in: directory) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func delete(_ references: [ClipboardBlobReference]) {
        guard let directory else { return }
        for reference in references {
            // Rich archives are macOS-only; iOS never writes one, so there is nothing to remove.
            let kind: SyncBlobKind
            switch reference.kind {
            case .image: kind = .image
            case .text: kind = .text
            case .rich: continue
            }
            guard let url = SyncBlobPolicy.containedURL(
                directory: directory,
                filename: reference.filename,
                kind: kind
            ) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Launch sweep

    /// Deletes every regular file directly in the blobs directory whose name isn't in
    /// `referenced` — a crash between a durable write and its deferred blob deletion (or a
    /// staged pull write and its rename) otherwise leaks the file forever. An unreadable
    /// listing is a silent no-op.
    /// - Returns: the number of files removed.
    @discardableResult
    func sweepOrphans(referenced: Set<String>) -> Int {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return 0 }
        var removedCount = 0
        for url in entries where !referenced.contains(url.lastPathComponent) {
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            guard isRegularFile == true else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removedCount += 1
            }
        }
        return removedCount
    }
}
