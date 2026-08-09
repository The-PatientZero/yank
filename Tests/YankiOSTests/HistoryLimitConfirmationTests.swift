import Foundation
import Testing
@testable import YankiOS

/// The iOS reduction flow end to end against the real `IOSSettings`. The cancel path is the
/// point: a reduction the user backed out of must leave nothing behind — not the value, not the
/// stamp that decides cross-device conflicts, and no announcement that would push it fleet-wide.
@Suite("iOS history limit confirmation")
@MainActor
struct HistoryLimitConfirmationTests {
    @Test("A reduction that would delete clips waits for confirmation")
    func destructiveReductionWaitsForConfirmation() throws {
        let confirmation = HistoryLimitConfirmation()

        let applied = confirmation.select(
            .essential,
            current: .unlimited,
            items: plainClips(101)
        )

        #expect(applied == nil)
        #expect(confirmation.isConfirming)
        #expect(confirmation.pendingTier == .essential)
    }

    @Test("A reduction that deletes nothing applies straight away")
    func harmlessReductionAppliesImmediately() {
        let confirmation = HistoryLimitConfirmation()

        let applied = confirmation.select(.essential, current: .unlimited, items: plainClips(4))

        #expect(applied == .essential)
        #expect(!confirmation.isConfirming)
    }

    @Test("Re-picking the current tier is inert")
    func repickingTheCurrentTierIsInert() {
        let confirmation = HistoryLimitConfirmation()

        let applied = confirmation.select(.deep, current: .deep, items: plainClips(900))

        #expect(applied == nil)
        #expect(!confirmation.isConfirming)
    }

    @Test("Cancelling leaves the value, the stamp, and sync untouched")
    func cancellingChangesNothing() throws {
        let fixture = try makeSettings()
        defer { fixture.cleanUp() }
        let settings = fixture.settings
        settings.setHistoryLimit(.unlimited)
        let stampBeforeReduction = settings.historyLimitUpdatedAt
        let announcements = NotificationCounter(name: .yankSyncedSettingsChanged)
        let confirmation = HistoryLimitConfirmation()

        let applied = confirmation.select(
            .essential,
            current: settings.historyLimit,
            items: plainClips(101)
        )
        #expect(applied == nil)
        confirmation.cancel()

        #expect(!confirmation.isConfirming)
        #expect(confirmation.pendingTier == nil)
        #expect(settings.historyLimit == .unlimited)
        #expect(settings.historyLimitUpdatedAt == stampBeforeReduction)
        #expect(announcements.count == 0)

        // And the abandoned choice is not lurking to be applied by a later confirm.
        #expect(confirmation.confirm() == nil)
        #expect(settings.historyLimit == .unlimited)
    }

    @Test("Confirming applies the tier, stamps it, and announces it once")
    func confirmingAppliesAndStamps() throws {
        let fixture = try makeSettings()
        defer { fixture.cleanUp() }
        let settings = fixture.settings
        settings.setHistoryLimit(.unlimited)
        let stampBeforeReduction = settings.historyLimitUpdatedAt
        let announcements = NotificationCounter(name: .yankSyncedSettingsChanged)
        let confirmation = HistoryLimitConfirmation()

        _ = confirmation.select(
            .essential,
            current: settings.historyLimit,
            items: plainClips(101)
        )
        let confirmed = try #require(confirmation.confirm())
        settings.setHistoryLimit(confirmed)

        #expect(confirmed == .essential)
        #expect(!confirmation.isConfirming)
        #expect(settings.historyLimit == .essential)
        #expect(settings.historyLimitUpdatedAt > stampBeforeReduction)
        #expect(announcements.count == 1)

        let reloaded = IOSSettings(defaults: fixture.defaults)
        #expect(reloaded.historyLimit == .essential)
        #expect(reloaded.historyLimitUpdatedAt == settings.historyLimitUpdatedAt)
    }

    // MARK: - Helpers

    private func plainClips(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { index in
            let date = Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            return ClipboardItem(
                type: .text,
                timestamp: date,
                textContent: "clip-\(index)",
                modifiedAt: date
            )
        }
    }

    private func makeSettings() throws -> SettingsFixture {
        let suiteName = "HistoryLimitConfirmationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsFixture(
            suiteName: suiteName,
            defaults: defaults,
            settings: IOSSettings(defaults: defaults)
        )
    }

    private struct SettingsFixture {
        let suiteName: String
        let defaults: UserDefaults
        let settings: IOSSettings

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

/// Counts a notification for the lifetime of the test, so "nothing was announced" is an
/// assertion rather than an assumption.
@MainActor
private final class NotificationCounter {
    private(set) var count = 0
    private var observer: (any NSObjectProtocol)?

    init(name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
