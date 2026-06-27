import Foundation

/// Strict loader for the on-disk history snapshot.
///
/// A missing file means "no local history yet"; an unreadable or malformed existing
/// file means "do not write over this path until a human/app flow can recover it."
enum HistorySnapshotLoader {
    struct Snapshot: Equatable, Sendable {
        var items: [ClipboardItem]
        var tombstones: [UUID: Date]
        /// Individually-malformed items that were skipped (the rest of the history still loaded).
        var skippedItemCount = 0
    }

    enum LoadError: Error, Equatable, LocalizedError {
        case unreadableHistory
        case corruptHistory
        case unreadableTombstones
        case corruptTombstones

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
            }
        }
    }

    static func load(historyURL: URL, tombstonesURL: URL) -> Result<Snapshot, LoadError> {
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
        do {
            // Decode element-by-element: one malformed clip is skipped rather than failing the
            // whole snapshot and locking the user out of all their history. A non-array top level
            // (a genuinely corrupt file) still throws, so the fail-closed protection holds.
            let decoded = try JSONDecoder().decode([FailableClipItem].self, from: historyData)
            items = decoded.compactMap(\.item)
            skippedItemCount = decoded.count - items.count
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

        return .success(Snapshot(items: items, tombstones: tombstones, skippedItemCount: skippedItemCount))
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
