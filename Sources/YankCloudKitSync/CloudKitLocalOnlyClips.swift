import Foundation
#if SWIFT_PACKAGE
import YankCore
#endif

/// Clips the user chose to keep on this device because they cannot be uploaded as they are.
/// Device-local sync state, stored next to the other `cloudkit.*` keys; older builds ignore it,
/// and a downgrade simply tries the clips again. An entry applies only to the exact version of
/// the clip that was kept: any edit changes `modifiedAt` and puts the clip back in the queue.
struct CloudKitLocalOnlyClips: Equatable {
    static let currentVersion = 1

    private struct Entry: Codable, Equatable {
        let id: UUID
        let modifiedAt: Date
    }

    private struct Envelope: Codable {
        let version: Int
        let entries: [Entry]
    }

    private var modifiedAtByID: [UUID: Date] = [:]

    var isEmpty: Bool { modifiedAtByID.isEmpty }

    /// A value that cannot be decoded is logged and treated as empty: the clips return to the
    /// queue, which is harmless.
    static func load(from defaults: UserDefaults, key: String) -> CloudKitLocalOnlyClips {
        guard let data = defaults.data(forKey: key) else { return CloudKitLocalOnlyClips() }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version <= currentVersion else {
                syncLog.error("kept-on-device clip list has an unknown version \(envelope.version, privacy: .public); ignoring it")
                return CloudKitLocalOnlyClips()
            }
            var result = CloudKitLocalOnlyClips()
            for entry in envelope.entries { result.modifiedAtByID[entry.id] = entry.modifiedAt }
            return result
        } catch {
            syncLog.error("kept-on-device clip list could not be read: \(error.localizedDescription, privacy: .public)")
            return CloudKitLocalOnlyClips()
        }
    }

    func persist(to defaults: UserDefaults, key: String) {
        guard !isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let entries = modifiedAtByID
            .map { Entry(id: $0.key, modifiedAt: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        do {
            defaults.set(try JSONEncoder().encode(Envelope(version: Self.currentVersion, entries: entries)), forKey: key)
        } catch {
            syncLog.error("kept-on-device clip list could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func isKept(_ item: ClipboardItem) -> Bool {
        modifiedAtByID[item.id] == item.modifiedAt
    }

    mutating func keep(_ items: [ClipboardItem]) {
        for item in items where !item.isDeleted { modifiedAtByID[item.id] = item.modifiedAt }
    }

    /// Drops entries whose clip is gone or was edited since. Returns whether anything changed.
    mutating func prune(against items: [ClipboardItem]) -> Bool {
        let current = Dictionary(items.map { ($0.id, $0.modifiedAt) }, uniquingKeysWith: { first, _ in first })
        let before = modifiedAtByID
        modifiedAtByID = modifiedAtByID.filter { current[$0.key] == $0.value }
        return modifiedAtByID != before
    }
}
