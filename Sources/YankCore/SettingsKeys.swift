import Foundation

/// `UserDefaults` keys shared cross-process: macOS, iOS, and the iOS extensions (reading
/// App-Group defaults directly) must agree on these strings, so they live here once. Pure
/// strings, no type deps, so lean extensions can compile against it.
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
