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
    static let retentionDays = 0
    static let syncEnabled = false
}
