import Foundation

/// Strict loader for the on-disk history snapshot.
///
/// A missing file means "no local history yet"; an unreadable or malformed existing
/// file means "do not write over this path until a human/app flow can recover it."
enum HistorySnapshotLoader {
    struct Snapshot: Equatable, Sendable {
        var items: [ClipboardItem]
        var tombstones: [UUID: Date]
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
        do {
            items = try JSONDecoder().decode([ClipboardItem].self, from: historyData)
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

        return .success(Snapshot(items: items, tombstones: tombstones))
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
