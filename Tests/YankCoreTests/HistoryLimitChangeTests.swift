import Foundation
import Testing
@testable import YankCore

/// The rule that decides whether reducing the history limit warns first. With the limit syncing
/// across devices, a false negative silently deletes clips on every device the user owns, and a
/// false positive trains people to dismiss a destructive warning that never meant anything.
@Suite struct HistoryLimitChangeTests {
    @Test func pickingTheCurrentTierDoesNothing() {
        let change = HistoryLimitChange.requested(.deep, current: .deep, items: manyPlainClips(500))

        #expect(change == .unchanged)
    }

    @Test func raisingTheLimitAppliesWithoutAsking() {
        let change = HistoryLimitChange.requested(
            .unlimited,
            current: .essential,
            items: manyPlainClips(500)
        )

        #expect(change == .apply(.unlimited))
    }

    @Test func reducingBelowTheClipCountAsksFirst() {
        let change = HistoryLimitChange.requested(
            .essential,
            current: .deep,
            items: manyPlainClips(101)
        )

        #expect(change == .confirm(.essential))
    }

    /// The case iOS used to get wrong in the other direction and macOS still warned about: a
    /// smaller number that deletes nothing should not raise a destructive prompt.
    @Test func reducingWithRoomToSpareAppliesWithoutAsking() {
        let change = HistoryLimitChange.requested(
            .essential,
            current: .unlimited,
            items: manyPlainClips(12)
        )

        #expect(change == .apply(.essential))
    }

    /// Protected clips are never evicted, so a history entirely made of them survives any cap.
    @Test func reducingAgainstOnlyProtectedClipsAppliesWithoutAsking() {
        let change = HistoryLimitChange.requested(
            .essential,
            current: .unlimited,
            items: (0..<150).map { clip(at: TimeInterval($0), isPinned: true) }
        )

        #expect(change == .apply(.essential))
    }

    /// Protected clips still consume the budget, so they can push unprotected ones out.
    @Test func protectedClipsConsumeBudgetAndCanForceAWarning() {
        let items = (0..<98).map { clip(at: TimeInterval($0), isPinned: true) }
            + (0..<5).map { clip(at: TimeInterval(1_000 + $0)) }

        let change = HistoryLimitChange.requested(.essential, current: .deep, items: items)

        #expect(change == .confirm(.essential))
    }

    /// Without a history to measure, a reduction must still announce itself.
    @Test func unknownHistoryFallsBackToTheCautiousTierComparison() {
        #expect(
            HistoryLimitChange.requested(.essential, current: .deep, items: nil)
                == .confirm(.essential)
        )
        #expect(
            HistoryLimitChange.requested(.unlimited, current: .deep, items: nil)
                == .apply(.unlimited)
        )
    }

    @Test func wouldEvictIgnoresADisabledLimit() {
        #expect(!ClipboardRetention.wouldEvict(manyPlainClips(50), limit: 0))
    }

    @Test func wouldEvictMatchesWhatCapActuallyRemoves() {
        let items = (0..<20).map { clip(at: TimeInterval($0), isPinned: $0 < 3) }

        for limit in [0, 1, 3, 5, 19, 20, 21, 100] {
            let removed = ClipboardRetention.cap(items, limit: limit).removedItems

            #expect(
                ClipboardRetention.wouldEvict(items, limit: limit) == !removed.isEmpty,
                "limit \(limit) disagreed with cap"
            )
        }
    }

    // MARK: - Helpers

    private func manyPlainClips(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { clip(at: TimeInterval($0)) }
    }

    private func clip(at secondsSinceReferenceDate: TimeInterval, isPinned: Bool = false) -> ClipboardItem {
        let date = Date(timeIntervalSinceReferenceDate: secondsSinceReferenceDate)
        return ClipboardItem(
            type: .text,
            timestamp: date,
            textContent: "clip-\(secondsSinceReferenceDate)",
            isPinned: isPinned,
            modifiedAt: date
        )
    }
}
