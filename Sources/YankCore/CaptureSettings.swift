import Foundation

/// The exact slice of user settings the capture critical path reads (history limit,
/// retention window, minimum capture length, capture exclusions). Injected into
/// `ClipboardStore` / `ClipboardWatcher` as a value instead of reaching for the
/// `SettingsManager.shared` process-wide singleton, so the capture logic is testable
/// in isolation.
///
/// The app keeps `SettingsManager` as the source of truth and feeds the stores a fresh
/// snapshot when the user changes a setting; the stores depend only on this value.
struct CaptureSettings: Equatable, Sendable {
    /// Maximum number of live clips to retain on this device. `0` disables the cap.
    var historyLimit: Int

    /// Auto-delete unprotected clips older than this many days. `0` keeps them forever.
    var retentionDays: Int

    /// Copies whose trimmed length is below this are never captured. `0` disables the rule.
    var minCaptureLength: Int

    /// Bundle identifiers whose copies are never captured.
    var excludedBundleIDs: Set<String>

    init(
        historyLimit: Int,
        retentionDays: Int,
        minCaptureLength: Int,
        excludedBundleIDs: Set<String>
    ) {
        self.historyLimit = historyLimit
        self.retentionDays = retentionDays
        self.minCaptureLength = minCaptureLength
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// A no-capture-rules baseline: unbounded history, no expiry, no min length, no
    /// exclusions. Convenient default for tests and for the iOS store, which only needs
    /// the storage-shaped fields.
    static let unbounded = CaptureSettings(
        historyLimit: 0,
        retentionDays: 0,
        minCaptureLength: 0,
        excludedBundleIDs: []
    )
}
