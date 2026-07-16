import Foundation

/// Atomic, file-per-capture handoff from the share extension to the host app.
///
/// The extension never rewrites canonical history. The host imports each entry using its
/// stable ID, commits canonical history durably, then removes the entry.
struct ShareCaptureInbox: Sendable {
    enum Error: Swift.Error, Equatable {
        case invalidEntry
        case unsupportedVersion
        case quotaExceeded
        case missingPayload
        case payloadTooLarge
        case textTooLarge
    }

    enum EntryKind: String, Codable, Sendable {
        case text
        case image
    }

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let version: Int
        let id: UUID
        let createdAt: Date
        let sourceApp: String?
        let kind: EntryKind
        let text: String?
    }

    static let currentVersion = 1
    static let entriesDirectoryName = "share-capture-inbox-v1"
    static let payloadsDirectoryName = "share-capture-payloads-v1"
    static let defaultMaxPendingCaptures = 50
    static let defaultMaxPendingBytes = 64 * 1_024 * 1_024

    let rootURL: URL
    let maxPendingCaptures: Int
    let maxPendingBytes: Int
    let writeOptions: Data.WritingOptions

    var entriesURL: URL {
        rootURL.appendingPathComponent(Self.entriesDirectoryName, isDirectory: true)
    }

    var payloadsURL: URL {
        rootURL.appendingPathComponent(Self.payloadsDirectoryName, isDirectory: true)
    }

    init(
        rootURL: URL,
        maxPendingCaptures: Int = defaultMaxPendingCaptures,
        maxPendingBytes: Int = defaultMaxPendingBytes,
        writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    ) {
        self.rootURL = rootURL
        self.maxPendingCaptures = maxPendingCaptures
        self.maxPendingBytes = maxPendingBytes
        self.writeOptions = writeOptions
    }

    @discardableResult
    func enqueue(
        text: String,
        sourceApp: String? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> Entry {
        let byteCount = text.utf8.count
        guard byteCount <= SyncBlobKind.text.maximumBytes else { throw Error.textTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.invalidEntry
        }
        let entry = Entry(
            version: Self.currentVersion,
            id: id,
            createdAt: createdAt,
            sourceApp: sourceApp,
            kind: .text,
            text: text
        )
        let data = try JSONEncoder().encode(entry)
        try prepareForEnqueue(addingBytes: data.count)
        try data.write(to: entryURL(for: id), options: writeOptions)
        return entry
    }

    @discardableResult
    func enqueue(
        imagePNG data: Data,
        sourceApp: String? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> Entry {
        guard !data.isEmpty, data.count <= SyncBlobKind.image.maximumBytes else {
            throw Error.payloadTooLarge
        }
        let entry = Entry(
            version: Self.currentVersion,
            id: id,
            createdAt: createdAt,
            sourceApp: sourceApp,
            kind: .image,
            text: nil
        )
        let entryData = try JSONEncoder().encode(entry)
        try prepareForEnqueue(addingBytes: data.count + entryData.count)

        let payloadURL = imagePayloadURL(for: id)
        do {
            try data.write(to: payloadURL, options: writeOptions)
            try entryData.write(to: entryURL(for: id), options: writeOptions)
        } catch {
            try? FileManager.default.removeItem(at: payloadURL)
            throw error
        }
        return entry
    }

    func pendingEntries() throws -> [Entry] {
        let entries = try entryURLs().map { try decodeEntry(at: $0) }
        return sorted(entries)
    }

    /// Host-only recovery scan. Corrupt temporary handoffs are unrecoverable, so discard
    /// them (and a same-ID image payload, if present) while continuing to return valid work.
    /// Strict callers can keep using `pendingEntries()` when corruption must surface.
    func recoverablePendingEntries() throws -> [Entry] {
        var entries: [Entry] = []
        for url in try entryURLs() {
            do {
                entries.append(try decodeEntry(at: url))
            } catch Error.invalidEntry {
                discardInvalidEntry(at: url)
            } catch Error.unsupportedVersion {
                continue
            } catch {
                throw error
            }
        }
        return sorted(entries)
    }

    private func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
    }

    private func entryURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: entriesURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: entriesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func decodeEntry(at url: URL) throws -> Entry {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw Error.invalidEntry }
        let entry: Entry
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        do {
            entry = try JSONDecoder().decode(Entry.self, from: data)
        } catch {
            throw Error.invalidEntry
        }
        guard entry.version == Self.currentVersion else { throw Error.unsupportedVersion }
        guard entryURL(for: entry.id).lastPathComponent == url.lastPathComponent,
              isValid(entry) else {
            throw Error.invalidEntry
        }
        return entry
    }

    private func discardInvalidEntry(at url: URL) {
        try? removeIfPresent(url)
        let stem = url.deletingPathExtension().lastPathComponent
        guard let id = UUID(uuidString: stem) else { return }
        try? removeIfPresent(imagePayloadURL(for: id))
    }

    func imagePayload(for entry: Entry) throws -> Data {
        guard entry.kind == .image else { throw Error.invalidEntry }
        let url = imagePayloadURL(for: entry.id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.missingPayload }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              (1...SyncBlobKind.image.maximumBytes).contains(fileSize) else {
            throw Error.payloadTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == fileSize else { throw Error.invalidEntry }
        return data
    }

    func remove(_ entry: Entry) throws {
        if entry.kind == .image {
            try removeIfPresent(imagePayloadURL(for: entry.id))
        }
        try removeIfPresent(entryURL(for: entry.id))
    }

    private func prepareForEnqueue(addingBytes: Int) throws {
        try FileManager.default.createDirectory(at: entriesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)

        let pendingCount = try regularFileURLs(in: entriesURL).filter { $0.pathExtension == "json" }.count
        guard pendingCount < maxPendingCaptures else { throw Error.quotaExceeded }
        let existingBytes = try [entriesURL, payloadsURL].reduce(0) { total, directory in
            try total + regularFileURLs(in: directory).reduce(0) { subtotal, url in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return subtotal + max(0, size)
            }
        }
        guard addingBytes >= 0,
              addingBytes <= maxPendingBytes,
              existingBytes <= maxPendingBytes - addingBytes else {
            throw Error.quotaExceeded
        }
    }

    private func regularFileURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }

    private func isValid(_ entry: Entry) -> Bool {
        switch entry.kind {
        case .text:
            guard let text = entry.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return text.utf8.count <= SyncBlobKind.text.maximumBytes
        case .image:
            return entry.text == nil
        }
    }

    private func entryURL(for id: UUID) -> URL {
        entriesURL.appendingPathComponent(id.uuidString, isDirectory: false).appendingPathExtension("json")
    }

    private func imagePayloadURL(for id: UUID) -> URL {
        payloadsURL.appendingPathComponent(id.uuidString, isDirectory: false).appendingPathExtension("png")
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
