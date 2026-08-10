import Foundation

/// Adapts `SettingsManager` to the sync transport's `SyncedSettingsStore` port, so the CloudKit
/// engine reads and writes the history limit without knowing the settings type exists.
///
/// Adoption goes through `adoptHistoryLimit`, whose `save()` posts `.yankCaptureSettingsChanged`
/// — the existing path that re-injects the capture snapshot and makes the store trim to the new
/// size. Nothing about retention is duplicated here.
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
