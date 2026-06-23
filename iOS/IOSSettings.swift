import SwiftUI

/// iOS user preferences, backed by the App-Group defaults so they survive relaunches.
/// Mirrors the slice of the Mac's `SettingsManager` that applies on iOS: accent theme,
/// layout, density, history limit, and auto-delete retention. Keys and defaults come
/// from the shared `SettingsKeys` / `SettingsDefaults`, and `ClipStore` reads the same
/// keys for limit/retention enforcement.
@MainActor
@Observable
final class IOSSettings {
    var themeID: String { didSet { defaults.set(themeID, forKey: SettingsKeys.themeID) } }
    var viewMode: ClipViewMode { didSet { defaults.set(viewMode.rawValue, forKey: SettingsKeys.viewMode) } }
    var density: ClipDensity { didSet { defaults.set(density.rawValue, forKey: SettingsKeys.density) } }
    var historyLimit: HistoryLimit { didSet { defaults.set(historyLimit.rawValue, forKey: SettingsKeys.historyLimit) } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: SettingsKeys.retentionDays) } }
    var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: SettingsKeys.syncEnabled) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: ClipStore.appGroup) ?? .standard) {
        self.defaults = defaults
        self.themeID = defaults.string(forKey: SettingsKeys.themeID) ?? SettingsDefaults.themeID
        self.viewMode = ClipViewMode(rawValue: defaults.string(forKey: SettingsKeys.viewMode) ?? "") ?? SettingsDefaults.viewMode
        self.density = ClipDensity(rawValue: defaults.string(forKey: SettingsKeys.density) ?? "") ?? SettingsDefaults.density
        self.historyLimit = HistoryLimit(rawValue: defaults.integer(forKey: SettingsKeys.historyLimit)) ?? SettingsDefaults.historyLimit
        self.retentionDays = defaults.integer(forKey: SettingsKeys.retentionDays)
        self.syncEnabled = defaults.object(forKey: SettingsKeys.syncEnabled) as? Bool ?? SettingsDefaults.syncEnabled
        seedDefaults()
    }

    /// Write the resolved values back when absent, so the lean `ClipStore` and the
    /// extensions — which read the App-Group defaults raw — enforce the same limit and
    /// retention the UI shows, rather than falling back to "unlimited" until the user
    /// first opens Settings. Only seeds missing keys, so it never clobbers a real choice.
    private func seedDefaults() {
        if defaults.object(forKey: SettingsKeys.historyLimit) == nil {
            defaults.set(historyLimit.rawValue, forKey: SettingsKeys.historyLimit)
        }
        if defaults.object(forKey: SettingsKeys.retentionDays) == nil {
            defaults.set(retentionDays, forKey: SettingsKeys.retentionDays)
        }
        if defaults.object(forKey: SettingsKeys.themeID) == nil {
            defaults.set(themeID, forKey: SettingsKeys.themeID)
        }
        if defaults.object(forKey: SettingsKeys.viewMode) == nil {
            defaults.set(viewMode.rawValue, forKey: SettingsKeys.viewMode)
        }
        if defaults.object(forKey: SettingsKeys.density) == nil {
            defaults.set(density.rawValue, forKey: SettingsKeys.density)
        }
        if defaults.object(forKey: SettingsKeys.syncEnabled) == nil {
            defaults.set(syncEnabled, forKey: SettingsKeys.syncEnabled)
        }
    }

    var theme: AppTheme { AppTheme.from(id: themeID) }
}
