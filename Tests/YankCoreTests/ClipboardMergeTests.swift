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

    private func enriched(_ n: Int, mod: Double, tags: [String], title: String?, enrichedAt: Double) -> ClipboardItem {
        ClipboardItem(
            id: clipID(n), type: .text, timestamp: Date(timeIntervalSinceReferenceDate: 1000),
            textContent: "item-\(n)", aiTags: tags, aiTitle: title,
            aiEnrichedAt: Date(timeIntervalSinceReferenceDate: enrichedAt),
            modifiedAt: Date(timeIntervalSinceReferenceDate: mod)
        )
    }

    @Test func enrichmentSurvivesNewerEditFromUnenrichedDevice() {
        // A device that never ran enrichment edits the clip later (newer modifiedAt, no AI).
        let unenrichedNewer = item(7, ts: 1000, mod: 3000)
        let enrichedOlder = enriched(7, mod: 2000, tags: ["aws", "error"], title: "AWS error", enrichedAt: 2000)
        let merged = ClipboardMerge.reconcile([enrichedOlder], [unenrichedNewer])
        #expect(merged.count == 1)
        // The newer edit wins the item, but the enrichment is carried forward, not erased.
        #expect(merged[0].modifiedAt == unenrichedNewer.modifiedAt)
        #expect(merged[0].aiTags == ["aws", "error"])
        #expect(merged[0].aiTitle == "AWS error")
        #expect(merged[0].aiEnrichedAt == enrichedOlder.aiEnrichedAt)
    }

    @Test func freshestEnrichmentWinsRegardlessOfItemWinner() {
        // Item winner is the newer-modified side; AI resolves on its own clock.
        let itemWinnerStaleAI = enriched(8, mod: 5000, tags: ["old"], title: "old", enrichedAt: 1000)
        let itemLoserFreshAI = enriched(8, mod: 4000, tags: ["new"], title: "new", enrichedAt: 9000)
        let merged = ClipboardMerge.reconcile([itemWinnerStaleAI], [itemLoserFreshAI])
        #expect(merged.count == 1)
        #expect(merged[0].modifiedAt == itemWinnerStaleAI.modifiedAt)
        #expect(merged[0].aiTags == ["new"])
        #expect(merged[0].aiEnrichedAt == itemLoserFreshAI.aiEnrichedAt)
    }
}
