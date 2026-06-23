import Testing
import Foundation
@testable import YankCore

@Suite struct ClipboardMergeTests {
    private func item(_ n: Int, ts: Double, mod: Double? = nil, deleted: Double? = nil) -> ClipboardItem {
        ClipboardItem(
            id: clipID(n),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: ts),
            textContent: "item-\(n)",
            modifiedAt: mod.map { Date(timeIntervalSinceReferenceDate: $0) },
            deletedAt: deleted.map { Date(timeIntervalSinceReferenceDate: $0) },
            deviceOrigin: "device-A"
        )
    }

    @Test func codableRoundTripPreservesSyncMetadata() throws {
        let original = item(1, ts: 1000, mod: 1500)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        #expect(decoded.modifiedAt == original.modifiedAt)
        #expect(decoded.deviceOrigin == "device-A")
        #expect(decoded.deletedAt == nil)
    }

    @Test func legacyRecordsMigrateToDefaults() throws {
        let data = try JSONEncoder().encode(item(1, ts: 1000, mod: 1500))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        ["modifiedAt", "deletedAt", "deviceOrigin"].forEach { json.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let migrated = try JSONDecoder().decode(ClipboardItem.self, from: legacyData)
        #expect(migrated.modifiedAt == migrated.timestamp)
        #expect(migrated.deletedAt == nil)
        #expect(migrated.deviceOrigin == "")
    }

    @Test func lastWriterWins() {
        let older = item(2, ts: 1000, mod: 1000)
        let newer = item(2, ts: 1000, mod: 2000)
        let merged = ClipboardMerge.reconcile([older], [newer])
        #expect(merged.count == 1)
        #expect(merged[0].modifiedAt == newer.modifiedAt)
    }

    @Test func newerTombstoneWinsAndVisibleFiltersIt() {
        let live = item(3, ts: 1000, mod: 1000)
        let tomb = item(3, ts: 1000, mod: 2000, deleted: 2000)
        let merged = ClipboardMerge.reconcile([live], [tomb])
        #expect(merged.count == 1)
        #expect(merged[0].isDeleted)
        #expect(ClipboardMerge.visible(merged).isEmpty)
    }

    @Test func disjointUnionOrdersNewestFirst() {
        let union = ClipboardMerge.reconcile([item(4, ts: 10)], [item(5, ts: 20)])
        #expect(union.count == 2)
        #expect(union[0].id == clipID(5))
    }

    @Test func deletionWinsModifiedAtTies() {
        let live = item(6, ts: 1000, mod: 1000)
        let del = item(6, ts: 1000, mod: 1000, deleted: 1000)
        let merged = ClipboardMerge.reconcile([live], [del])
        #expect(merged.count == 1)
        #expect(merged[0].isDeleted)
    }
}
