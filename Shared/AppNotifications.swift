import Foundation

extension Notification.Name {
    static let yankIgnoreNextChange = Notification.Name("yankIgnoreNextChange")
    static let yankHotkeyChanged = Notification.Name("yankHotkeyChanged")
    static let yankWindowDidOpen = Notification.Name("yankWindowDidOpen")
    /// Posted when the history window is summoned, not when it merely regains key status.
    static let yankHistoryWindowDidShow = Notification.Name("yankHistoryWindowDidShow")
    static let yankMenuBarVisibilityChanged = Notification.Name("yankMenuBarVisibilityChanged")
    static let yankThemeChanged = Notification.Name("yankThemeChanged")
    static let yankAppearanceChanged = Notification.Name("yankAppearanceChanged")
    static let yankOpenSettings = Notification.Name("yankOpenSettings")
    static let yankSpotlightIndexingChanged = Notification.Name("yankSpotlightIndexingChanged")
    static let yankAITaggingChanged = Notification.Name("yankAITaggingChanged")
    static let yankCaptureSettingsChanged = Notification.Name("yankCaptureSettingsChanged")
    static let yankSyncPreferenceChanged = Notification.Name("yankSyncPreferenceChanged")
    static let yankDidCapture = Notification.Name("yankDidCapture")
    static let yankUpdateStateChanged = Notification.Name("yankUpdateStateChanged")
    /// Posted whenever the sync status, its failure cause or the waiting-clip list changes.
    static let yankSyncStatusChanged = Notification.Name("yankSyncStatusChanged")
    /// Posted by Settings and the menu-bar menu to ask for a sync right now.
    static let yankSyncNowRequested = Notification.Name("yankSyncNowRequested")
    /// Posted by Settings to stop waiting for clips that cannot upload; carries `SyncNotificationKey.clipIDs`.
    static let yankKeepClipsLocalRequested = Notification.Name("yankKeepClipsLocalRequested")
}

enum SyncNotificationKey {
    static let clipIDs = "clipIDs"
}
