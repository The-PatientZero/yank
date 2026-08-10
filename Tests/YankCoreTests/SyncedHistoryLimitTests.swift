import Foundation
import Testing
@testable import YankCore

/// The choose-versus-adopt stamp rule, owned in one place so macOS and iOS cannot drift.
/// Getting this wrong is what makes two devices trade the same value back and forth forever.
@Suite struct SyncedHistoryLimitTests {
    @Test func aFreshValueCountsAsNeverChosen() {
        let limit = SyncedHistoryLimit(historyLimit: .essential)

        #expect(limit.updatedAt == .distantPast)
        #expect(!limit.current.wasChosen)
    }

    @Test func choosingStampsTheMomentAndReportsTheChange() {
        var limit = SyncedHistoryLimit(historyLimit: .essential)
        let now = Date(timeIntervalSinceReferenceDate: 500)

        let didChange = limit.choose(.deep, at: now)

        #expect(didChange)
        #expect(limit.historyLimit == .deep)
        #expect(limit.updatedAt == now)
        #expect(limit.current.wasChosen)
    }

    /// Re-picking the current value is not a choice, so nothing is announced and — critically —
    /// the stamp does not move, which would otherwise let a stale value outrank a real one.
    @Test func rechoosingTheSameValueChangesNothing() {
        var limit = SyncedHistoryLimit(historyLimit: .deep, updatedAt: Date(timeIntervalSinceReferenceDate: 100))

        let didChange = limit.choose(.deep, at: Date(timeIntervalSinceReferenceDate: 900))

        #expect(!didChange)
        #expect(limit.updatedAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test func adoptingKeepsTheRemoteStampVerbatim() {
        var limit = SyncedHistoryLimit(historyLimit: .essential, updatedAt: Date(timeIntervalSinceReferenceDate: 100))
        let remote = SyncedSettings(
            historyLimit: .unlimited,
            updatedAt: Date(timeIntervalSinceReferenceDate: 400)
        )

        limit.adopt(remote)

        #expect(limit.historyLimit == .unlimited)
        #expect(limit.updatedAt == remote.updatedAt)
        #expect(limit.current == remote)
    }

    /// Adopting must not look like a local choice: if it re-stamped to "now", this device would
    /// outrank the origin and push the value straight back.
    @Test func adoptingAnOlderRemoteValueDoesNotInventANewerStamp() {
        var limit = SyncedHistoryLimit(historyLimit: .deep, updatedAt: Date(timeIntervalSinceReferenceDate: 900))
        let older = SyncedSettings(
            historyLimit: .essential,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        limit.adopt(older)

        #expect(limit.updatedAt == older.updatedAt)
    }

    @Test func wasChosenTracksTheStampNotTheValue() {
        let unchosen = SyncedSettings(historyLimit: .unlimited, updatedAt: .distantPast)
        let chosen = SyncedSettings(
            historyLimit: .essential,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )

        #expect(!unchosen.wasChosen)
        #expect(chosen.wasChosen)
    }
}
