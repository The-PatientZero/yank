import Foundation

/// Adapts `IOSSettings` to the sync transport's `SyncedSettingsStore` port. Unlike macOS, which
/// re-trims off `.yankCaptureSettingsChanged`, iOS has no such broadcast — adoption re-applies
/// retention directly here since `SettingsView`'s `onChange` only fires while on screen.
@MainActor
final class IOSSyncedSettingsBridge: SyncedSettingsStore {
    private let settings: IOSSettings
    private weak var store: ClipStore?

    init(settings: IOSSettings, store: ClipStore) {
        self.settings = settings
        self.store = store
    }

    /// `nil` without the App Group: preferences cannot be persisted, so this device has no
    /// durable opinion to weigh against a remote one.
    var syncedSettings: SyncedSettings? {
        guard !settings.storageUnavailable else { return nil }
        return settings.syncedSettings
    }

    func applySyncedSettings(_ syncedSettings: SyncedSettings) {
        settings.adoptHistoryLimit(syncedSettings)
        store?.enforceRetentionAndLimit()
    }
}
