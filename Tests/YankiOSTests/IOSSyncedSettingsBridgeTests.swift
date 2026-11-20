import Foundation
import Testing
@testable import YankiOS

/// Adopting another device's history limit trims this device immediately and without asking —
/// the confirmation happened on the device that made the choice. That makes the protection
/// contract the only thing standing between a remote choice and someone's kept clips, so it is
/// pinned here rather than left to the shared retention unit test.
@Suite("iOS synced settings bridge")
@MainActor
struct IOSSyncedSettingsBridgeTests {
    @Test("Adopting a smaller limit prunes only unprotected clips")
    func adoptingASmallerLimitKeepsProtectedClips() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // Start above the tier being adopted so nothing is capped until the adoption itself.
        fixture.context.defaults.set(
            HistoryLimit.unlimited.rawValue,
            forKey: SettingsKeys.historyLimit
        )

        // The protected three are also the *oldest*, so a cap that ignored protection would
        // evict exactly them.
        let pinned = item(text: "pinned", at: 1, isPinned: true)
        let bookmarked = item(text: "bookmarked", at: 2, isBookmarked: true)
        let tagged = item(text: "tagged", at: 3, tags: ["keep"])
        let plain = (0..<102).map { item(text: "plain-\($0)", at: TimeInterval(100 + $0)) }
        let oldestPlain = try #require(plain.first)
        let newestPlain = try #require(plain.last)
        try writeHistory([pinned, bookmarked, tagged] + plain, in: fixture)

        let store = ClipStore(context: fixture.context)
        let settings = IOSSettings(defaults: fixture.context.defaults)
        let bridge = IOSSyncedSettingsBridge(settings: settings, store: store)
        #expect(store.items.count == 105)

        bridge.applySyncedSettings(
            SyncedSettings(
                historyLimit: .essential,
                updatedAt: Date(timeIntervalSinceReferenceDate: 900)
            )
        )

        let keptIDs = Set(store.items.map(\.id))
        #expect(keptIDs.contains(pinned.id))
        #expect(keptIDs.contains(bookmarked.id))
        #expect(keptIDs.contains(tagged.id))
        // 100 budget: the 3 protected clips plus the newest 97 plain ones.
        #expect(store.items.count == 100)
        #expect(keptIDs.contains(newestPlain.id))
        #expect(!keptIDs.contains(oldestPlain.id))
    }

    @Test("Adoption keeps the origin device's stamp so the value cannot bounce back")
    func adoptionKeepsTheRemoteStamp() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        let settings = IOSSettings(defaults: fixture.context.defaults)
        let bridge = IOSSyncedSettingsBridge(settings: settings, store: store)
        let remote = SyncedSettings(
            historyLimit: .deep,
            updatedAt: Date(timeIntervalSinceReferenceDate: 700)
        )

        bridge.applySyncedSettings(remote)

        #expect(settings.historyLimit == .deep)
        #expect(settings.historyLimitUpdatedAt == remote.updatedAt)
        // A remote record with no retention opinion (an older build's) keeps the local window,
        // so the adopted value matches the remote everywhere except that preserved field.
        #expect(bridge.syncedSettings?.historyLimit == remote.historyLimit)
        #expect(bridge.syncedSettings?.updatedAt == remote.updatedAt)
        #expect(bridge.syncedSettings?.retentionDays == settings.retentionDays)
    }

    @Test("Without the App Group there is no durable opinion to weigh")
    func missingAppGroupReportsNoSyncedSettings() {
        let settings = IOSSettings(defaults: nil)
        let store = ClipStore(context: nil)
        let bridge = IOSSyncedSettingsBridge(settings: settings, store: store)

        #expect(bridge.syncedSettings == nil)
    }

    // MARK: - Helpers

    private func item(
        text: String,
        at secondsSinceReferenceDate: TimeInterval,
        isPinned: Bool = false,
        isBookmarked: Bool = false,
        tags: [String] = []
    ) -> ClipboardItem {
        let date = Date(timeIntervalSinceReferenceDate: secondsSinceReferenceDate)
        return ClipboardItem(
            type: .text,
            timestamp: date,
            textContent: text,
            isPinned: isPinned,
            isBookmarked: isBookmarked,
            tags: tags,
            modifiedAt: date
        )
    }

    private func writeHistory(_ items: [ClipboardItem], in fixture: Fixture) throws {
        try JSONEncoder().encode(items).write(to: fixture.context.historyURL, options: .atomic)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSSyncedSettingsBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "IOSSyncedSettingsBridgeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        return Fixture(
            root: root,
            defaultsName: defaultsName,
            context: AppGroupContext(containerURL: root, defaults: defaults)
        )
    }

    private struct Fixture {
        let root: URL
        let defaultsName: String
        let context: AppGroupContext

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
    }
}
