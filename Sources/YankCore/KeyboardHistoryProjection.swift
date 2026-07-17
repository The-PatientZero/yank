import Foundation

/// A bounded, read-only view of canonical history for the keyboard extension.
///
/// The persisted DTO intentionally carries only fields needed to insert and label text.
/// Full `ClipboardItem` metadata can include large search/OCR/AI payloads and must never
/// cross into the memory-constrained keyboard process.
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

        init(item: ClipboardItem, textContent: String) {
            self.id = item.id
            self.timestamp = item.timestamp
            self.sourceApp = item.sourceApp
            self.textContent = textContent
        }

        var clipboardItem: ClipboardItem {
            ClipboardItem(
                id: id,
                type: .text,
                timestamp: timestamp,
                sourceApp: sourceApp,
                textContent: textContent,
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
        maxItems: Int = defaultMaxItems,
        maxEncodedBytes: Int = defaultMaxEncodedBytes
    ) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.encodedByteLimit = max(0, maxEncodedBytes)

        let encoder = JSONEncoder()
        let emptyPayload = Payload(version: version, generatedAt: generatedAt, items: [])
        var encodedBytes = (try? encoder.encode(emptyPayload).count) ?? Int.max
        var projected: [ProjectedItem] = []
        projected.reserveCapacity(min(max(0, maxItems), items.count))

        for item in items where projected.count < max(0, maxItems) {
            guard !item.isDeleted, let text = item.textContent else { continue }
            let candidate = ProjectedItem(item: item, textContent: text)
            guard let candidateBytes = try? encoder.encode(candidate).count else { continue }
            let separatorBytes = projected.isEmpty ? 0 : 1
            let additionalBytes = candidateBytes + separatorBytes
            guard encodedBytes <= encodedByteLimit,
                  additionalBytes <= encodedByteLimit - encodedBytes else { continue }
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
