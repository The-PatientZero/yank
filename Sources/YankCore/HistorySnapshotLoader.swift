import Foundation

/// Strict loader for the on-disk history snapshot. A missing file means "no local history yet";
/// an unreadable or malformed one means "do not write over this path until a human/app flow can
/// recover it."
enum HistorySnapshotLoader {
    struct Snapshot: Equatable, Sendable {
        var items: [ClipboardItem]
        var tombstones: [UUID: Date]
        /// Individually-malformed items that were skipped (the rest of the history still loaded).
        var skippedItemCount = 0
        /// Skipped elements that are still JSON objects with a valid clip `id`. They are kept
        /// byte for byte so a later build that can read them finds them again.
        var heldElements: [HeldHistoryElement] = []
    }

    enum LoadError: Error, Equatable, LocalizedError {
        case unreadableHistory
        case corruptHistory
        case unreadableTombstones
        case corruptTombstones
        case unreadableTransaction
        case corruptTransaction
        case transactionRecoveryFailed

        var errorDescription: String? {
            switch self {
            case .unreadableHistory:
                "The saved history file could not be read."
            case .corruptHistory:
                "The saved history file is not valid Yank history."
            case .unreadableTombstones:
                "The saved deletion log could not be read."
            case .corruptTombstones:
                "The saved deletion log is not valid Yank history."
            case .unreadableTransaction:
                "The pending history transaction could not be read."
            case .corruptTransaction:
                "The pending history transaction is not valid Yank history."
            case .transactionRecoveryFailed:
                "The pending history transaction could not be recovered."
            }
        }
    }

    static func load(historyURL: URL, tombstonesURL: URL) -> Result<Snapshot, LoadError> {
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: historyURL)
        if FileManager.default.fileExists(atPath: transactionURL.path) {
            do {
                try HistorySnapshotTransaction.replayIfPresent(
                    historyURL: historyURL,
                    tombstonesURL: tombstonesURL
                )
            } catch let error as HistorySnapshotTransactionError {
                switch error {
                case .invalidEnvelope, .unsupportedVersion:
                    return .failure(.corruptTransaction)
                case .tombstoneEncodingFailed:
                    return .failure(.transactionRecoveryFailed)
                }
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                return .failure(.unreadableTransaction)
            } catch {
                return .failure(.transactionRecoveryFailed)
            }
        }

        let historyData: Data
        switch existingFileData(at: historyURL, unreadableError: .unreadableHistory) {
        case .success(let data?):
            historyData = data
        case .success(nil):
            historyData = Data("[]".utf8)
        case .failure(let error):
            return .failure(error)
        }

        let items: [ClipboardItem]
        let skippedItemCount: Int
        var heldElements: [HeldHistoryElement] = []
        do {
            // Decode element-by-element: one malformed clip is skipped rather than failing the
            // whole snapshot and locking the user out of all their history. A non-array top level
            // (a genuinely corrupt file) still throws, so the fail-closed protection holds.
            let decoded = try JSONDecoder().decode([FailableClipItem].self, from: historyData)
            items = decoded.compactMap(\.item)
            skippedItemCount = decoded.count - items.count
            if skippedItemCount > 0 {
                // The element slices only matter when something failed, so the common load
                // never scans. A slice count that disagrees with the decoder fails closed.
                guard let slices = HistoryElementScanner.topLevelElements(in: historyData),
                      slices.count == decoded.count else {
                    return .failure(.corruptHistory)
                }
                for (element, slice) in zip(decoded, slices) where element.item == nil {
                    if let held = HeldHistoryElement(data: slice) {
                        heldElements.append(held)
                    }
                }
            }
        } catch {
            return .failure(.corruptHistory)
        }

        let tombstones: [UUID: Date]
        switch existingFileData(at: tombstonesURL, unreadableError: .unreadableTombstones) {
        case .success(let data?):
            do {
                tombstones = try TombstoneCodec.decodeStrict(data)
            } catch {
                return .failure(.corruptTombstones)
            }
        case .success(nil):
            tombstones = [:]
        case .failure(let error):
            return .failure(error)
        }

        heldElements = HeldHistoryElement.kept(
            heldElements,
            tombstones: tombstones,
            liveIDs: Set(items.map(\.id))
        )
        return .success(Snapshot(
            items: items,
            tombstones: tombstones,
            skippedItemCount: skippedItemCount,
            heldElements: heldElements
        ))
    }

    /// Decodes one history element, yielding `nil` for an individually-malformed item so the
    /// rest of the snapshot still loads.
    private struct FailableClipItem: Decodable {
        let item: ClipboardItem?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            item = try? container.decode(ClipboardItem.self)
        }
    }

    private static func existingFileData(
        at url: URL,
        unreadableError: LoadError
    ) -> Result<Data?, LoadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(nil)
        }
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(unreadableError)
        }
    }
}

/// A history element this build cannot decode as a clip but that is still a JSON object with a
/// valid clip `id`. The original bytes are written back unchanged on every save, together with
/// the files they name, so a build that can read the clip finds it intact.
struct HeldHistoryElement: Equatable, Sendable {
    let data: Data
    let id: UUID
    let timestamp: Date?
    let modifiedAt: Date?
    /// Every bare filename found in any string value of the element, at any depth.
    let filenames: Set<String>

    /// Returns `nil` when `data` is not a JSON object with a valid clip `id`; such an element is
    /// not a clip and is dropped.
    init?(data: Data) {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        self.data = data
        self.id = probe.id
        self.timestamp = probe.timestamp
        self.modifiedAt = probe.modifiedAt
        self.filenames = Self.bareFilenames(in: object)
    }

    /// Elements that should still be kept: drops an element when a readable clip has the same id,
    /// or when a deletion record for its id is at least as new as the element (the same
    /// last-writer-wins rule sync uses). With no usable date on the element, any deletion record
    /// for its id drops it.
    static func kept(
        _ held: [HeldHistoryElement],
        tombstones: [UUID: Date],
        liveIDs: Set<UUID>
    ) -> [HeldHistoryElement] {
        held.filter { element in
            if liveIDs.contains(element.id) { return false }
            guard let deletedAt = tombstones[element.id] else { return true }
            guard let elementDate = element.modifiedAt ?? element.timestamp else { return false }
            return deletedAt < elementDate
        }
    }

    private struct Probe: Decodable {
        enum CodingKeys: String, CodingKey { case id, timestamp, modifiedAt }

        let id: UUID
        let timestamp: Date?
        let modifiedAt: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            timestamp = try? container.decode(Date.self, forKey: .timestamp)
            modifiedAt = try? container.decode(Date.self, forKey: .modifiedAt)
        }
    }

    private static func bareFilenames(in value: Any) -> Set<String> {
        switch value {
        case let string as String:
            return isBareFilename(string) ? [string] : []
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { $0.formUnion(bareFilenames(in: $1)) }
        case let object as [String: Any]:
            return object.values.reduce(into: Set<String>()) { $0.formUnion(bareFilenames(in: $1)) }
        default:
            return []
        }
    }

    private static func isBareFilename(_ string: String) -> Bool {
        !string.isEmpty
            && string.contains(".")
            && !string.contains("/")
            && !string.contains("\\")
            && !string.contains(":")
    }
}

/// Splits the top-level JSON array of a history file into the raw bytes of each element, so
/// elements the decoder rejects can be written back unchanged.
enum HistoryElementScanner {
    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Returns `nil` when the data is not a well-formed UTF-8 array at the top level.
    static func topLevelElements(in data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var index = bytes.starts(with: utf8ByteOrderMark) ? utf8ByteOrderMark.count : 0
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
        index += 1

        var elements: [Data] = []
        var start: Int?
        var end = index
        var depth = 0
        var inString = false
        var escaped = false
        var closed = false

        func finishElement() -> Bool {
            guard let begin = start else { return false }
            elements.append(Data(bytes[begin..<end]))
            start = nil
            return true
        }

        scan: while index < bytes.count {
            let byte = bytes[index]
            defer { index += 1 }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                end = index + 1
                continue
            }
            if isWhitespace(byte) { continue }
            switch byte {
            case UInt8(ascii: "\""):
                if start == nil { start = index }
                inString = true
                end = index + 1
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                if start == nil { start = index }
                depth += 1
                end = index + 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if depth > 0 {
                    depth -= 1
                    end = index + 1
                } else if byte == UInt8(ascii: "]") {
                    // The closing bracket of the history array. An empty array has no element.
                    if start != nil, !finishElement() { return nil }
                    closed = true
                    break scan
                } else {
                    return nil
                }
            case UInt8(ascii: ","):
                if depth > 0 {
                    end = index + 1
                } else if !finishElement() {
                    return nil
                }
            default:
                if start == nil { start = index }
                end = index + 1
            }
        }

        guard closed, !inString else { return nil }
        // Only whitespace may follow the closing bracket.
        return bytes[index...].allSatisfy(isWhitespace) ? elements : nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
