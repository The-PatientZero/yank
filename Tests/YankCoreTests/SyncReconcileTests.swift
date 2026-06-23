import Foundation
import Testing
@testable import YankCore

@Suite struct SyncReconcileTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func live(_ n: Int, ageSeconds: Double) -> ClipboardItem {
        ClipboardItem(id: clipID(n), type: .text, timestamp: t0.addingTimeInterval(ageSeconds),
                      textContent: "item-\(n)")
    }

    @Test func tombstoneItemsMaterialiseDeletedAt() {
        let date = t0.addingTimeInterval(500)
        let items = SyncReconcile.tombstoneItems([clipID(9): date])
        #expect(items.count == 1)
        #expect(items[0].id == clipID(9))
        #expect(items[0].deletedAt == date)
        #expect(items[0].isDeleted)
    }

    @Test func splitSeparatesVisibleNewestFirstAndTombstones() {
        let deletedAt = t0.addingTimeInterval(300)
        let dead = ClipboardItem(id: clipID(3), type: .text, timestamp: deletedAt,
                                 modifiedAt: deletedAt, deletedAt: deletedAt)
        let canonical = [live(1, ageSeconds: 100), dead, live(2, ageSeconds: 200)]

        let (visible, tombstones) = SyncReconcile.split(canonical)

        #expect(visible.map(\.id) == [clipID(2), clipID(1)])   // newest-first, tombstone excluded
        #expect(tombstones == [clipID(3): deletedAt])
    }

    @Test func applyCapsVisibleItemsAndReportsRemovedBlobReferences() {
        let oldImage = ClipboardItem(
            id: clipID(9),
            type: .image,
            timestamp: t0,
            imageFilename: "11111111-1111-4111-8111-111111111111.png"
        )
        let kept = ClipboardItem(
            id: clipID(1),
            type: .text,
            timestamp: t0.addingTimeInterval(300),
            textContent: "keep"
        )
        let dropped = ClipboardItem(
            id: clipID(2),
            type: .text,
            timestamp: t0.addingTimeInterval(200),
            textContent: "drop"
        )
        let deletedAt = t0.addingTimeInterval(400)
        let tombstone = ClipboardItem(
            id: clipID(3),
            type: .text,
            timestamp: deletedAt,
            modifiedAt: deletedAt,
            deletedAt: deletedAt
        )

        let result = SyncReconcile.apply(
            canonical: [kept, dropped, tombstone],
            replacing: [oldImage],
            historyLimit: 1,
            retentionDays: 0,
            now: t0
        )

        #expect(result.visibleItems.map(\.id) == [kept.id])
        #expect(result.tombstones == [tombstone.id: deletedAt])
        #expect(result.expiredVisibleCount == 0)
        #expect(result.cappedVisibleCount == 1)
        #expect(result.blobReferencesToDelete == [
            ClipboardBlobReference(kind: .image, filename: "11111111-1111-4111-8111-111111111111.png")
        ])
    }

    @Test func applyExpiresOldRemoteVisibleItemAndTombstonesIt() {
        let oldImage = ClipboardItem(
            id: clipID(20),
            type: .image,
            timestamp: t0,
            imageFilename: "\(clipID(20).uuidString).png"
        )
        let fresh = live(21, ageSeconds: 39 * 86_400)

        let result = SyncReconcile.apply(
            canonical: [oldImage, fresh],
            replacing: [],
            historyLimit: 0,
            retentionDays: 30,
            now: t0.addingTimeInterval(40 * 86_400)
        )

        #expect(result.visibleItems == [fresh])
        #expect(result.tombstones == [oldImage.id: t0.addingTimeInterval(40 * 86_400)])
        #expect(result.expiredVisibleCount == 1)
        #expect(result.cappedVisibleCount == 0)
        #expect(result.blobReferencesToDelete == [
            ClipboardBlobReference(kind: .image, filename: "\(clipID(20).uuidString).png")
        ])
    }

    @Test func applyCapOnlyRemovalDoesNotAddTombstones() {
        let kept = live(30, ageSeconds: 200)
        let dropped = live(31, ageSeconds: 100)

        let result = SyncReconcile.apply(
            canonical: [kept, dropped],
            replacing: [],
            historyLimit: 1,
            retentionDays: 0,
            now: t0
        )

        #expect(result.visibleItems == [kept])
        #expect(result.tombstones.isEmpty)
        #expect(result.expiredVisibleCount == 0)
        #expect(result.cappedVisibleCount == 1)
    }

    @Test func applyKeepsOldProtectedRemoteItem() {
        let oldProtected = ClipboardItem(
            id: clipID(40),
            type: .text,
            timestamp: t0,
            textContent: "protected",
            isPinned: true
        )

        let result = SyncReconcile.apply(
            canonical: [oldProtected],
            replacing: [],
            historyLimit: 0,
            retentionDays: 30,
            now: t0.addingTimeInterval(40 * 86_400)
        )

        #expect(result.visibleItems == [oldProtected])
        #expect(result.tombstones.isEmpty)
        #expect(result.expiredVisibleCount == 0)
        #expect(result.cappedVisibleCount == 0)
    }

    @Test func applyZeroHistoryLimitDisablesCap() {
        let items = [live(50, ageSeconds: 200), live(51, ageSeconds: 100)]

        let result = SyncReconcile.apply(
            canonical: items,
            replacing: [],
            historyLimit: 0,
            retentionDays: 0,
            now: t0
        )

        #expect(result.visibleItems == items)
        #expect(result.tombstones.isEmpty)
        #expect(result.cappedVisibleCount == 0)
    }

    @Test func tombstoneCodecRoundTrips() throws {
        let map: [UUID: Date] = [clipID(1): t0, clipID(2): t0.addingTimeInterval(60)]
        let data = try #require(TombstoneCodec.encode(map))
        #expect(TombstoneCodec.decode(data) == map)
    }

    @Test func tombstoneCodecDecodesGarbageToEmpty() {
        #expect(TombstoneCodec.decode(Data("not json".utf8)).isEmpty)
    }
}
