import Foundation
import Testing
@testable import YankCore

@Suite struct ClipboardRetentionTombstoneTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    private func tombstones(agesDays: [Int]) -> [UUID: Date] {
        var map: [UUID: Date] = [:]
        for (n, ageDays) in agesDays.enumerated() {
            map[clipID(n)] = now.addingTimeInterval(-Double(ageDays) * 86_400)
        }
        return map
    }

    @Test func keepsTombstonesYoungerThanHorizon() {
        let map = tombstones(agesDays: [0, 1, 30, 119])
        let pruned = ClipboardRetention.prunedTombstones(map, now: now)
        #expect(pruned.count == map.count)
    }

    @Test func dropsTombstonesAtOrPastHorizon() {
        // Horizon default is 120 days: exactly-120 and older age out; 119 survives.
        let map = tombstones(agesDays: [119, 120, 150])
        let pruned = ClipboardRetention.prunedTombstones(map, now: now)
        #expect(Set(pruned.keys) == [clipID(0)])
    }

    @Test func customHorizonIsHonoured() {
        let map = tombstones(agesDays: [5, 10, 20])
        let pruned = ClipboardRetention.prunedTombstones(map, now: now, horizonDays: 7)
        #expect(Set(pruned.keys) == [clipID(0)])
    }

    @Test func nonPositiveHorizonDisablesPruning() {
        let map = tombstones(agesDays: [100, 500])
        #expect(ClipboardRetention.prunedTombstones(map, now: now, horizonDays: 0).count == map.count)
        #expect(ClipboardRetention.prunedTombstones(map, now: now, horizonDays: -3).count == map.count)
    }

    @Test func horizonExceedsAnyPlausibleRetentionWindow() {
        // A still-live clip on one device must never be resurrected by an already-aged-out
        // tombstone, so the tombstone horizon must strictly exceed the maximum user-configurable
        // retention window (90 days). Guard the invariant against future tweaks to either value.
        #expect(ClipboardRetention.tombstoneHorizonDays > 90)
    }
}
