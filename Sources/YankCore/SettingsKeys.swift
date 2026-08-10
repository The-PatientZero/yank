import Foundation

/// The `UserDefaults` keys for settings that both platforms persist. This is a
/// cross-process contract — the macOS app, the iOS app, and the iOS extensions
/// (which read the App-Group defaults directly) must agree on these strings, so they
/// live here once rather than as scattered literals. Pure strings, no type deps, so
/// the lean extensions can compile against it.
enum SettingsKeys {
    static let themeID = "themeID"
    static let viewMode = "clipViewMode"
    static let density = "clipDensity"
    static let historyLimit = "historyLimit"
    /// When the user last chose `historyLimit`. Stored beside the value it stamps so the two
    /// can never disagree, and read by the CloudKit sync bridge to settle cross-device races.
    static let historyLimitUpdatedAt = "historyLimitUpdatedAt"
    static let retentionDays = "retentionDays"
    static let syncEnabled = "syncEnabled"
    /// Whether captured clips are pushed into system-wide Core Spotlight. Off by default:
    /// clipboard history can contain secrets, so system-wide indexing is opt-in.
    static let spotlightIndexing = "spotlightIndexing"
}
