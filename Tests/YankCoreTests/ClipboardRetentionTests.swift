import Foundation
import Testing
@testable import YankCore

@Suite struct ClipboardRetentionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func item(_ n: Int, ageDays: Double, pinned: Bool = false, bookmarked: Bool = false, tags: [String] = []) -> ClipboardItem {
        ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
            type: .text,
            timestamp: now.addingTimeInterval(-ageDays * 86_400),
            textContent: "item-\(n)",
            isPinned: pinned,
            isBookmarked: bookmarked,
            tags: tags
        )
    }

    private var sample: [ClipboardItem] {
        [
            item(1, ageDays: 40),
            item(2, ageDays: 3),
            item(3, ageDays: 40, pinned: true),
            item(4, ageDays: 40, bookmarked: true),
            item(5, ageDays: 40, tags: ["x"])
        ]
    }

    @Test func zeroDisablesExpiry() {
        #expect(ClipboardRetention.expiredItems(sample, olderThanMinutes: 0 * SyncedSettings.minutesPerDay, now: now).map(\.id).isEmpty)
    }

    @Test func onlyOldUnprotectedItemExpires() {
        let expired = ClipboardRetention.expiredItems(sample, olderThanMinutes: 30 * SyncedSettings.minutesPerDay, now: now).map(\.id)
        #expect(expired.count == 1)
        #expect(expired.first == sample[0].id)
    }

    @Test func protectedItemsAreNeverExpired() {
        let expired = Set(ClipboardRetention.expiredItems(sample, olderThanMinutes: 30 * SyncedSettings.minutesPerDay, now: now).map(\.id))
        #expect(!(expired.contains(sample[2].id)))
        #expect(!(expired.contains(sample[3].id)))
        #expect(!(expired.contains(sample[4].id)))
    }

    @Test func expiredItemsReturnFullItemsForStoreCleanup() {
        let oldImage = ClipboardItem(
            id: clipID(20),
            type: .image,
            timestamp: now.addingTimeInterval(-40 * 86_400),
            imageFilename: "old-image.png",
            richFilename: "old-rich.plist"
        )
        let pinnedOldImage = ClipboardItem(
            id: clipID(21),
            type: .image,
            timestamp: now.addingTimeInterval(-40 * 86_400),
            imageFilename: "pinned-image.png",
            richFilename: "pinned-rich.plist",
            isPinned: true
        )
        let freshText = item(22, ageDays: 3)

        let expired = ClipboardRetention.expiredItems(
            [freshText, oldImage, pinnedOldImage],
            olderThanMinutes: 30 * SyncedSettings.minutesPerDay,
            now: now
        )

        #expect(expired.map(\.id) == [oldImage.id])
        guard let expiredItem = expired.first else {
            Issue.record("Expected old unprotected image to expire")
            return
        }
        #expect(expiredItem.imageFilename == "old-image.png")
        #expect(expiredItem.richFilename == "old-rich.plist")
    }

    @Test func nothingOlderThanWindow() {
        #expect(ClipboardRetention.expiredItems(sample, olderThanMinutes: 90 * SyncedSettings.minutesPerDay, now: now).map(\.id).isEmpty)
    }

    @Test func hourWindowExpiresUnprotectedClipsOlderThanIt() {
        let recent = item(6, ageDays: 1.0 / 24)
        let older = item(7, ageDays: 5.0 / 24)
        let pinned = item(8, ageDays: 5.0 / 24, pinned: true)

        let expired = ClipboardRetention.expiredItems([recent, older, pinned], olderThanMinutes: 240, now: now)

        #expect(expired.map(\.id) == [older.id])
    }

    @Test func nextExpiryIsTheOldestUnprotectedClipPlusTheWindow() {
        let newer = item(6, ageDays: 1.0 / 24)
        let oldest = item(7, ageDays: 3.0 / 24)
        let pinned = item(8, ageDays: 10, pinned: true)

        let next = ClipboardRetention.nextExpiry(of: [newer, oldest, pinned], retentionMinutes: 240)

        #expect(next == oldest.timestamp.addingTimeInterval(240 * 60))
    }

    @Test func nothingExpiresWithoutAWindowOrUnprotectedClips() {
        #expect(ClipboardRetention.nextExpiry(of: sample, retentionMinutes: 0) == nil)
        #expect(ClipboardRetention.nextExpiry(of: [item(3, ageDays: 1, pinned: true)], retentionMinutes: 60) == nil)
    }

    // MARK: - capped

    @Test func capBelowLimitReturnsAllNewestFirst() {
        let capped = ClipboardRetention.capped(sample, limit: 100)
        #expect(capped.count == sample.count)
        // Newest (item 2, 3 days old) first.
        #expect(capped.first?.id == item(2, ageDays: 3).id)
    }

    @Test func capKeepsNewestUnprotectedWithinBudget() {
        let items = (1...10).map { item($0, ageDays: Double(11 - $0)) } // item 10 newest
        let capped = ClipboardRetention.capped(items, limit: 3)
        #expect(capped.count == 3)
        #expect(capped.map(\.id) == [item(10, ageDays: 1).id, item(9, ageDays: 2).id, item(8, ageDays: 3).id])
    }

    @Test func capAlwaysKeepsProtectedEvenBeyondLimit() {
        let items = [
            item(1, ageDays: 1),
            item(2, ageDays: 2),
            item(3, ageDays: 50, pinned: true),
            item(4, ageDays: 60, bookmarked: true),
            item(5, ageDays: 70, tags: ["x"])
        ]
        let capped = ClipboardRetention.capped(items, limit: 1)
        // 3 protected are kept despite limit 1; 0 budget left for unprotected.
        #expect(Set(capped.map(\.id)) == [item(3, ageDays: 50).id, item(4, ageDays: 60).id, item(5, ageDays: 70).id])
    }

    @Test func capReportsRemovedItemsAndBlobReferences() {
        let keptImage = ClipboardItem(
            id: clipID(30),
            type: .image,
            timestamp: now,
            imageFilename: "\(clipID(30).uuidString).png"
        )
        let removedText = ClipboardItem(
            id: clipID(31),
            type: .text,
            timestamp: now.addingTimeInterval(-1),
            textContent: "preview",
            textFilename: "\(clipID(31).uuidString).txt"
        )

        let result = ClipboardRetention.cap([removedText, keptImage], limit: 1)

        #expect(result.items == [keptImage])
        #expect(result.removedItems == [removedText])
        #expect(result.blobReferencesToDelete == [
            ClipboardBlobReference(kind: .text, filename: "\(clipID(31).uuidString).txt")
        ])
    }

    @Test func capResultKeepsAllProtectedItemsBeyondLimit() {
        let protected = [
            item(40, ageDays: 1, pinned: true),
            item(41, ageDays: 2, bookmarked: true),
            item(42, ageDays: 3, tags: ["keep"])
        ]

        let result = ClipboardRetention.cap(protected, limit: 1)

        #expect(Set(result.items.map(\.id)) == Set(protected.map(\.id)))
        #expect(result.removedItems.isEmpty)
        #expect(result.blobReferencesToDelete.isEmpty)
    }

    @Test func capZeroLimitDisablesCap() {
        let capped = ClipboardRetention.capped(sample, limit: 0)
        #expect(capped.count == sample.count)
    }

    @Test func enforceExpiresOldUnprotectedAndDatesTombstonesFromTheExpiredClip() {
        let old = item(50, ageDays: 40)
        let fresh = item(51, ageDays: 2)

        let result = ClipboardRetention.enforce(
            items: [old, fresh],
            tombstones: [:],
            historyLimit: 0,
            retentionMinutes: 30 * SyncedSettings.minutesPerDay,
            now: now
        )

        #expect(result.items == [fresh])
        #expect(result.tombstones == [old.id: ClipboardRetention.expiryTombstoneDate(for: old)])
        #expect(result.expiredItems == [old])
        #expect(result.cappedItems.isEmpty)
        #expect(result.didChange)
    }

    @Test func enforceKeepsOldProtectedItems() {
        let protected = [
            item(60, ageDays: 40, pinned: true),
            item(61, ageDays: 40, bookmarked: true),
            item(62, ageDays: 40, tags: ["keep"])
        ]

        let result = ClipboardRetention.enforce(
            items: protected,
            tombstones: [:],
            historyLimit: 0,
            retentionMinutes: 30 * SyncedSettings.minutesPerDay,
            now: now
        )

        #expect(Set(result.items.map(\.id)) == Set(protected.map(\.id)))
        #expect(result.tombstones.isEmpty)
        #expect(result.expiredItems.isEmpty)
        #expect(!result.didChange)
    }

    @Test func enforceCapsAfterExpiryAndReportsOnlyLocalBlobCleanup() {
        let expiredImageFilename = "\(clipID(70).uuidString).png"
        let cappedTextFilename = "\(clipID(71).uuidString).txt"
        let expired = ClipboardItem(
            id: clipID(70),
            type: .image,
            timestamp: now.addingTimeInterval(-40 * 86_400),
            imageFilename: expiredImageFilename
        )
        let capped = ClipboardItem(
            id: clipID(71),
            type: .text,
            timestamp: now.addingTimeInterval(-2 * 86_400),
            textContent: "preview",
            textFilename: cappedTextFilename
        )
        let kept = item(72, ageDays: 1)

        let result = ClipboardRetention.enforce(
            items: [expired, capped, kept],
            tombstones: [:],
            historyLimit: 1,
            retentionMinutes: 30 * SyncedSettings.minutesPerDay,
            now: now
        )

        #expect(result.items == [kept])
        #expect(result.tombstones == [expired.id: ClipboardRetention.expiryTombstoneDate(for: expired)])
        #expect(result.expiredItems == [expired])
        #expect(result.cappedItems == [capped])
        #expect(Set(result.blobReferencesToDelete) == [
            ClipboardBlobReference(kind: .image, filename: expiredImageFilename),
            ClipboardBlobReference(kind: .text, filename: cappedTextFilename)
        ])
    }

    @Test func enforceKeepsOldTombstonesUntilAcknowledged() {
        let stale = now.addingTimeInterval(-121 * 86_400)
        let fresh = now.addingTimeInterval(-1 * 86_400)

        let result = ClipboardRetention.enforce(
            items: [],
            tombstones: [clipID(80): stale, clipID(81): fresh],
            historyLimit: 0,
            retentionMinutes: 0 * SyncedSettings.minutesPerDay,
            now: now
        )

        #expect(result.tombstones == [clipID(80): stale, clipID(81): fresh])
        #expect(!result.didChange)
    }

    @Test func enforceZeroLimitAndZeroRetentionAreDisabled() {
        let items = [item(90, ageDays: 5), item(91, ageDays: 40)]

        let result = ClipboardRetention.enforce(
            items: items,
            tombstones: [:],
            historyLimit: 0,
            retentionMinutes: 0 * SyncedSettings.minutesPerDay,
            now: now
        )

        #expect(result.items == items)
        #expect(result.expiredItems.isEmpty)
        #expect(result.cappedItems.isEmpty)
        #expect(!result.didChange)
    }
}
