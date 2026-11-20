import Foundation
import Testing
@testable import YankCore

/// The settings keys are a cross-process persistence contract — the macOS app, the iOS
/// app, and the iOS extensions all read/write these exact strings via the App Group.
/// Pin them so a rename can't silently desync stored preferences.
@Suite struct SettingsKeysTests {
    @Test func keyStringsAreStable() {
        #expect(SettingsKeys.themeID == "themeID")
        #expect(SettingsKeys.viewMode == "clipViewMode")
        #expect(SettingsKeys.density == "clipDensity")
        #expect(SettingsKeys.historyLimit == "historyLimit")
        #expect(SettingsKeys.historyLimitUpdatedAt == "historyLimitUpdatedAt")
        #expect(SettingsKeys.retentionDays == "retentionDays")
    }
}
