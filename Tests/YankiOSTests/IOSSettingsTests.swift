import Foundation
import Testing
@testable import YankiOS

@Suite("iOS Settings")
@MainActor
struct IOSSettingsTests {
    @Test("Missing App Group defaults is surfaced without a standard-defaults fallback")
    func missingSharedDefaultsFailsClosed() {
        let settings = IOSSettings(defaults: nil)

        #expect(settings.storageUnavailable)
        #expect(!settings.syncEnabled)
        #expect(!settings.spotlightIndexing)
    }

    @Test("iCloud sync defaults off and persists explicit opt-in")
    func syncDefaultsOffAndPersistsOptIn() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = IOSSettings(defaults: defaults)
        #expect(!initial.syncEnabled)
        #expect(defaults.bool(forKey: SettingsKeys.syncEnabled) == false)

        initial.syncEnabled = true
        let reloaded = IOSSettings(defaults: defaults)
        #expect(reloaded.syncEnabled)
    }

    @Test("Seeds shared defaults for extensions")
    func seedsSharedDefaultsForExtensions() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = IOSSettings(defaults: defaults)

        #expect(defaults.integer(forKey: SettingsKeys.historyLimit) == settings.historyLimit.rawValue)
        #expect(defaults.object(forKey: SettingsKeys.retentionDays) != nil)
        #expect(defaults.string(forKey: SettingsKeys.themeID) == settings.themeID)
        #expect(defaults.string(forKey: SettingsKeys.viewMode) == settings.viewMode.rawValue)
        #expect(defaults.string(forKey: SettingsKeys.density) == settings.density.rawValue)
        #expect(defaults.object(forKey: SettingsKeys.syncEnabled) != nil)
        #expect(defaults.object(forKey: SettingsKeys.spotlightIndexing) != nil)
    }

    @Test("Appearance and retention choices persist")
    func appearanceAndRetentionChoicesPersist() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = IOSSettings(defaults: defaults)
        settings.themeID = "mint"
        settings.viewMode = .grid
        settings.density = .snug
        settings.historyLimit = .essential
        settings.retentionDays = 30
        settings.spotlightIndexing = true

        let reloaded = IOSSettings(defaults: defaults)
        #expect(reloaded.themeID == "mint")
        #expect(reloaded.viewMode == .grid)
        #expect(reloaded.density == .snug)
        #expect(reloaded.historyLimit == .essential)
        #expect(reloaded.retentionDays == 30)
        #expect(reloaded.spotlightIndexing)
    }
}
