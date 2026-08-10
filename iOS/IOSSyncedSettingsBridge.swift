import Foundation

/// Adapts `IOSSettings` to the sync transport's `SyncedSettingsStore` port, so the CloudKit
/// engine reads and writes the history limit without knowing the settings type exists.
///
/// Unlike macOS — where saving preferences posts `.yankCaptureSettingsChanged` and the store
/// re-trims off the back of it — iOS has no such broadcast, so adoption re-applies retention
/// directly. `SettingsView`'s own `onChange` only fires while Settings is on screen.
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
