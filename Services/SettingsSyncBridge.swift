import Foundation

/// Adapts `SettingsManager` to the sync transport's `SyncedSettingsStore` port so CloudKit reads
/// and writes the history limit without knowing the settings type. Adoption flows through
/// `adoptHistoryLimit` → `save()`, which already re-trims history — do not duplicate that here.
@MainActor
final class SettingsSyncBridge: SyncedSettingsStore {
    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    var syncedSettings: SyncedSettings? { settings.syncedSettings }

    func applySyncedSettings(_ settings: SyncedSettings) {
        self.settings.adoptHistoryLimit(settings)
    }
}
