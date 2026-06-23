import Foundation

/// The default values for the cross-platform settings, in one place so macOS and iOS
/// agree out of the box. Typed (so it references the shared `AppTheme` / `ClipViewMode`
/// / `ClipDensity` / `HistoryLimit`), hence it lives in `Shared/` with those types and
/// is compiled into the two apps — not the lean extensions, which only read raw keys.
enum SettingsDefaults {
    static let themeID = AppTheme.amber.id
    static let viewMode: ClipViewMode = .list
    static let density: ClipDensity = .cozy
    /// Conservative by design — a clipboard manager shouldn't hoard. Was inconsistent
    /// (macOS `.essential`, iOS `.unlimited`); unified to `.essential` on both.
    static let historyLimit: HistoryLimit = .essential
    /// `0` = keep forever (auto-delete off).
    static let retentionDays = 0
    static let syncEnabled = false
}
