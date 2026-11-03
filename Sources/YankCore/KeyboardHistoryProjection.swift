import Foundation

extension ClipboardItem {
    /// True when `textContent` is only a preview of the clip's text: the full text lives in a blob
    /// file the keyboard never reads, or was too large to keep at all.
    var holdsOnlyPreview: Bool { isTruncated || isFileBacked }
}

/// A bounded, read-only view of canonical history for the keyboard extension. The DTO carries
/// only fields needed to insert and label text — full `ClipboardItem` metadata can include large
/// search/OCR/AI payloads and must never cross into the memory-constrained keyboard process.
struct KeyboardHistoryProjection: Codable, Sendable {
    enum Error: Swift.Error, Equatable {
        case encodedSizeExceeded(Int)
        case invalidFile
        case unsupportedVersion(Int)
    }

    private struct ProjectedItem: Codable, Sendable {
        let id: UUID
        let timestamp: Date
        let sourceApp: String?
        let textContent: String
        /// True when `textContent` is only a preview of the clip's text. Files written by older
        /// releases lack the key; it decodes as false and older readers ignore it.
        let isPreviewOnly: Bool

        init(item: ClipboardItem, textContent: String) {
            self.id = item.id
            self.timestamp = item.timestamp
            self.sourceApp = item.sourceApp
            self.textContent = textContent
            self.isPreviewOnly = item.holdsOnlyPreview
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(UUID.self, forKey: .id)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
            self.sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
            self.textContent = try container.decode(String.self, forKey: .textContent)
            self.isPreviewOnly = try container.decodeIfPresent(Bool.self, forKey: .isPreviewOnly) ?? false
        }

        var clipboardItem: ClipboardItem {
            ClipboardItem(
                id: id,
                type: .text,
                timestamp: timestamp,
                sourceApp: sourceApp,
                textContent: textContent,
                // The keyboard copy has no blob file; `isTruncated` carries "preview only" so
                // `holdsOnlyPreview` answers the same here as for the original clip.
                isTruncated: isPreviewOnly,
                modifiedAt: timestamp
            )
        }
    }

    private struct Payload: Codable {
        let version: Int
        let generatedAt: Date
        let items: [ProjectedItem]
    }

    static let currentVersion = 1
    static let filename = "keyboard-history-v1.json"
    static let defaultMaxCandidates = 1_000
    static let defaultMaxItems = 100
    static let defaultMaxEncodedBytes = 512 * 1_024

    let version: Int
    let generatedAt: Date
    private let projectedItems: [ProjectedItem]
    private var encodedByteLimit: Int

    var items: [ClipboardItem] { projectedItems.map(\.clipboardItem) }

    init(
        items: [ClipboardItem],
        generatedAt: Date = Date(),
        maxCandidates: Int = defaultMaxCandidates,
        maxItems: Int = defaultMaxItems,
        maxEncodedBytes: Int = defaultMaxEncodedBytes
    ) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.encodedByteLimit = max(0, maxEncodedBytes)

        let candidateLimit = max(0, maxCandidates)
        let itemLimit = max(0, maxItems)
        let encoder = JSONEncoder()
        let emptyPayload = Payload(version: version, generatedAt: generatedAt, items: [])
        var encodedBytes = (try? encoder.encode(emptyPayload).count) ?? Int.max
        var projected: [ProjectedItem] = []
        projected.reserveCapacity(min(candidateLimit, itemLimit, items.count))

        var consideredCandidates = 0
        for item in items {
            guard consideredCandidates < candidateLimit,
                  projected.count < itemLimit,
                  encodedBytes < encodedByteLimit else { break }
            consideredCandidates += 1
            guard !item.isDeleted, let text = item.textContent else { continue }
            let candidate = ProjectedItem(item: item, textContent: text)
            guard let candidateBytes = try? encoder.encode(candidate).count else { continue }
            let separatorBytes = projected.isEmpty ? 0 : 1
            let additionalBytes = candidateBytes + separatorBytes
            guard encodedBytes <= encodedByteLimit,
                  additionalBytes <= encodedByteLimit - encodedBytes else { break }
            projected.append(candidate)
            encodedBytes += additionalBytes
        }
        self.projectedItems = projected
    }

    private init(payload: Payload, encodedByteLimit: Int) throws {
        guard payload.version == Self.currentVersion else {
            throw Error.unsupportedVersion(payload.version)
        }
        self.version = payload.version
        self.generatedAt = payload.generatedAt
        self.projectedItems = payload.items
        self.encodedByteLimit = encodedByteLimit
    }

    init(from decoder: Decoder) throws {
        try self.init(
            payload: Payload(from: decoder),
            encodedByteLimit: Self.defaultMaxEncodedBytes
        )
    }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }

    func encoded(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let data = try encoder.encode(payload)
        guard data.count <= encodedByteLimit else {
            throw Error.encodedSizeExceeded(encodedByteLimit)
        }
        return data
    }

    static func decode(
        _ data: Data,
        maxEncodedBytes: Int = defaultMaxEncodedBytes,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Self {
        let byteLimit = max(0, maxEncodedBytes)
        guard data.count <= byteLimit else { throw Error.encodedSizeExceeded(byteLimit) }
        var projection = try decoder.decode(Self.self, from: data)
        projection.encodedByteLimit = byteLimit
        return projection
    }

    func write(
        to url: URL,
        options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    ) throws {
        try encoded().write(to: url, options: options)
    }

    static func load(
        from url: URL,
        maxEncodedBytes: Int = defaultMaxEncodedBytes
    ) throws -> Self {
        let byteLimit = max(0, maxEncodedBytes)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw Error.invalidFile
        }
        guard fileSize <= byteLimit else { throw Error.encodedSizeExceeded(byteLimit) }
        return try decode(
            Data(contentsOf: url, options: .mappedIfSafe),
            maxEncodedBytes: byteLimit
        )
    }

    private var payload: Payload {
        Payload(version: version, generatedAt: generatedAt, items: projectedItems)
    }
}
