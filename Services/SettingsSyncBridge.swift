import Foundation

/// Adapts `SettingsManager` to the sync transport's `SyncedSettingsStore` port so CloudKit reads
/// and writes the history limit without knowing the settings type. Adoption flows through
/// `adoptHistoryLimit` → `save()`, whose notification re-trims history only after a main-queue
/// hop; the store is therefore updated here as well, so a pull that adopts a limit and then
/// applies clips in the same stretch caps them under the adopted limit. Adoption happens before
/// the pulled clips are merged, so the store applies the cap only and leaves age expiry to the
/// end of the pull.
@MainActor
final class SettingsSyncBridge: SyncedSettingsStore {
    private let settings: SettingsManager
    private let store: ClipboardStore

    init(settings: SettingsManager, store: ClipboardStore) {
        self.settings = settings
        self.store = store
    }

    var syncedSettings: SyncedSettings? { settings.syncedSettings }

    func applySyncedSettings(_ settings: SyncedSettings) {
        self.settings.adoptHistoryLimit(settings)
        // `captureSettings` is `Equatable`, so the later notification hop assigns an equal value
        // and does nothing.
        store.adoptSyncedCaptureSettings(self.settings.captureSettings)
    }
}
