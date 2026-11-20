import Foundation

/// Cross-platform default settings values, shared so macOS and iOS agree out of the box.
/// Lives in `Shared/`, not the lean extensions, because it references the shared setting types.
enum SettingsDefaults {
    static let themeID = AppTheme.amber.id
    static let viewMode: ClipViewMode = .list
    static let density: ClipDensity = .cozy
    /// Conservative by design — a clipboard manager shouldn't hoard.
    static let historyLimit: HistoryLimit = .essential
    /// `0` = keep forever (auto-delete off).
    static let retentionMinutes = 0
    /// Auto-delete windows in minutes, offered on every platform in the order shown. `0` is "Never".
    static let retentionChoices = [0, 60, 240, 720] + [1, 7, 30, 90].map { $0 * SyncedSettings.minutesPerDay }
    static let syncEnabled = false

    /// The stored auto-delete window, carrying forward a whole-day choice saved by an older build.
    static func storedRetentionMinutes(in defaults: UserDefaults) -> Int {
        if defaults.object(forKey: SettingsKeys.retentionMinutes) != nil {
            return defaults.integer(forKey: SettingsKeys.retentionMinutes)
        }
        return defaults.integer(forKey: SettingsKeys.legacyRetentionDays) * SyncedSettings.minutesPerDay
    }
}
