import Foundation

/// Pure helpers for the CloudKit sync transport, shared by the macOS `ClipboardStore`
/// and the iOS `ClipStore` so both materialise and split the canonical set identically.
/// The stores keep their own I/O (directory layout, save queue); only this logic is shared.
enum SyncReconcile {
    struct ApplyResult: Equatable, Sendable {
        var visibleItems: [ClipboardItem]
        var tombstones: [UUID: Date]
        var blobReferencesToDelete: [ClipboardBlobReference]
        var expiredVisibleCount: Int
        var cappedVisibleCount: Int
    }

    /// Materialise a tombstone map as soft-deleted items, so deletions ride the same
    /// canonical channel as live clips.
    static func tombstoneItems(_ tombstones: [UUID: Date]) -> [ClipboardItem] {
        tombstones.map { id, date in
            ClipboardItem(id: id, type: .text, timestamp: date, modifiedAt: date, deletedAt: date)
        }
    }

    /// Split a reconciled canonical set into the visible clips (newest-first) and the
    /// tombstone map to retain. Callers then apply their own retention cap to `visible`.
    static func split(_ canonical: [ClipboardItem]) -> (visible: [ClipboardItem], tombstones: [UUID: Date]) {
        let visible = ClipboardMerge.visible(canonical).sorted { $0.timestamp > $1.timestamp }
        let tombstones = canonical.reduce(into: [UUID: Date]()) { acc, item in
            if let deletedAt = item.deletedAt { acc[item.id] = deletedAt }
        }
        return (visible, tombstones)
    }

    /// Resolve canonical sync state into the platform-store mutations and file-cleanup effects.
    /// Stores still own filesystem layout and persistence; this keeps the retention/tombstone
    /// decisions shared between macOS and iOS.
    static func apply(
        canonical: [ClipboardItem],
        replacing previousItems: [ClipboardItem],
        historyLimit: Int,
        retentionDays: Int,
        now: Date
    ) -> ApplyResult {
        let (visible, tombstones) = split(canonical)
        let enforced = ClipboardRetention.enforce(
            items: visible,
            tombstones: tombstones,
            historyLimit: historyLimit,
            retentionDays: retentionDays,
            now: now
        )
        let cleanup = Set(ClipboardBlobCleanup.referencesRemoved(from: previousItems, keeping: enforced.items))
            .union(enforced.blobReferencesToDelete)
        return ApplyResult(
            visibleItems: enforced.items,
            tombstones: enforced.tombstones,
            blobReferencesToDelete: sorted(cleanup),
            expiredVisibleCount: enforced.expiredItems.count,
            cappedVisibleCount: enforced.cappedItems.count
        )
    }

    private static func sorted(_ references: Set<ClipboardBlobReference>) -> [ClipboardBlobReference] {
        references.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.filename < $1.filename
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}

/// JSON codec for the on-disk tombstone log (`[UUID: Date]` ⇄ `[String: Date]`),
/// shared by both stores' persistence so the format never drifts.
enum TombstoneCodec {
    enum DecodeError: Error, Equatable {
        case invalidUUIDKey(String)
        case duplicateUUID(UUID)
    }

    static func encode(_ tombstones: [UUID: Date]) -> Data? {
        let raw = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.key.uuidString, $0.value) })
        return try? JSONEncoder().encode(raw)
    }

    static func decode(_ data: Data) -> [UUID: Date] {
        (try? decodeStrict(data)) ?? [:]
    }

    static func decodeStrict(_ data: Data) throws -> [UUID: Date] {
        let raw = try JSONDecoder().decode([String: Date].self, from: data)
        var decoded: [UUID: Date] = [:]
        for (key, date) in raw {
            guard let id = UUID(uuidString: key) else {
                throw DecodeError.invalidUUIDKey(key)
            }
            guard decoded.updateValue(date, forKey: id) == nil else {
                throw DecodeError.duplicateUUID(id)
            }
        }
        return decoded
    }
}
