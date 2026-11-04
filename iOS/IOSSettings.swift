import SwiftUI

enum IOSCaptureMethod: String, CaseIterable, Identifiable, Sendable {
    case keyboard
    case shareSheet
    case shortcut

    var id: Self { self }
}

enum IOSForegroundCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case undecided
    case automatic
    case explicitOnly

    static let decisionChoices: [IOSForegroundCaptureMode] = [.automatic, .explicitOnly]
    static let settingsChoices: [IOSForegroundCaptureMode] = [
        .undecided,
        .automatic,
        .explicitOnly
    ]

    var id: Self { self }

    var choiceTitle: String {
        switch self {
        case .undecided: "Ask Next Time"
        case .automatic: "Check When Yank Opens"
        case .explicitOnly: "Only When I Ask"
        }
    }

    var choiceDescription: String {
        switch self {
        case .undecided:
            "Yank does not check the clipboard and may ask again after a cold relaunch."
        case .automatic:
            "Saves eligible clipboard text when Yank becomes active. iOS may ask for paste permission."
        case .explicitOnly:
            "Saves only through Share or Save Clipboard. The keyboard remains read-only."
        }
    }
}

/// iOS user preferences, backed by App-Group defaults so they survive relaunches. Mirrors the
/// iOS-relevant slice of macOS `SettingsManager`; keys come from shared `SettingsKeys`/
/// `SettingsDefaults`, which `ClipStore` reads directly for limit/retention enforcement.
@MainActor
@Observable
final class IOSSettings {
    var themeID: String { didSet { defaults?.set(themeID, forKey: SettingsKeys.themeID) } }
    var viewMode: ClipViewMode { didSet { defaults?.set(viewMode.rawValue, forKey: SettingsKeys.viewMode) } }
    var density: ClipDensity { didSet { defaults?.set(density.rawValue, forKey: SettingsKeys.density) } }
    /// Value plus stamp in one place, so the limit can never move without its stamp. The
    /// choose-versus-adopt rule lives in `SyncedHistoryLimit` and is shared with macOS.
    private var syncedHistoryLimit: SyncedHistoryLimit {
        didSet {
            defaults?.set(syncedHistoryLimit.historyLimit.rawValue, forKey: SettingsKeys.historyLimit)
            defaults?.set(
                syncedHistoryLimit.current.retentionDays ?? SettingsDefaults.retentionDays,
                forKey: SettingsKeys.retentionDays
            )
            defaults?.set(syncedHistoryLimit.updatedAt, forKey: SettingsKeys.historyLimitUpdatedAt)
        }
    }

    var historyLimit: HistoryLimit { syncedHistoryLimit.historyLimit }
    /// When the history limit was last chosen. `distantPast` means "never explicitly chosen on
    /// this device", which lets any device that has made a real choice win the first sync
    /// without silently resizing anyone's history on upgrade.
    var historyLimitUpdatedAt: Date { syncedHistoryLimit.updatedAt }
    var syncedSettings: SyncedSettings { syncedHistoryLimit.current }
    /// Auto-delete window in days (0 = keep forever). Synced: expiry mints tombstones that
    /// propagate, so the window must be one account-wide choice.
    var retentionDays: Int {
        syncedHistoryLimit.current.retentionDays ?? SettingsDefaults.retentionDays
    }
    var syncEnabled: Bool { didSet { defaults?.set(syncEnabled, forKey: SettingsKeys.syncEnabled) } }
    var spotlightIndexing: Bool { didSet { defaults?.set(spotlightIndexing, forKey: SettingsKeys.spotlightIndexing) } }
    /// Device-local and not part of `SyncedSettings`: it never reaches CloudKit or the Mac.
    var includeHistoryInBackups: Bool {
        didSet { defaults?.set(includeHistoryInBackups, forKey: SettingsKeys.includeHistoryInBackups) }
    }
    private(set) var foregroundCaptureMode: IOSForegroundCaptureMode
    var confirmedCaptureMethods: Set<IOSCaptureMethod> {
        didSet {
            defaults?.set(
                confirmedCaptureMethods.map(\.rawValue).sorted(),
                forKey: Self.confirmedCaptureMethodsKey
            )
        }
    }
    var captureSetupCompleted: Bool {
        didSet { defaults?.set(captureSetupCompleted, forKey: Self.captureSetupCompletedKey) }
    }
    let storageUnavailable: Bool

    private static let confirmedCaptureMethodsKey = "iosConfirmedCaptureMethods"
    private static let captureSetupCompletedKey = "iosCaptureSetupCompleted"
    static let foregroundCaptureModeKey = "iosForegroundCaptureMode"
    private static let shareCaptureSource = "Share"
    private static let shortcutCaptureSources: Set<String> = ["Shortcuts", "Action Button"]

    private let defaults: UserDefaults?

    /// Everything `init` reads from the App Group defaults, so a later re-read gets the same answer.
    @MainActor
    private struct StoredValues {
        let themeID: String
        let viewMode: ClipViewMode
        let density: ClipDensity
        let syncedHistoryLimit: SyncedHistoryLimit
        let syncEnabled: Bool
        let spotlightIndexing: Bool
        let includeHistoryInBackups: Bool
        let foregroundCaptureMode: IOSForegroundCaptureMode
        let confirmedCaptureMethods: Set<IOSCaptureMethod>
        let captureSetupCompleted: Bool

        init(defaults: UserDefaults?) {
            themeID = defaults?.string(forKey: SettingsKeys.themeID) ?? SettingsDefaults.themeID
            viewMode = ClipViewMode(
                rawValue: defaults?.string(forKey: SettingsKeys.viewMode) ?? ""
            ) ?? SettingsDefaults.viewMode
            density = ClipDensity(
                rawValue: defaults?.string(forKey: SettingsKeys.density) ?? ""
            ) ?? SettingsDefaults.density
            syncedHistoryLimit = SyncedHistoryLimit(
                historyLimit: HistoryLimit(
                    rawValue: defaults?.integer(forKey: SettingsKeys.historyLimit) ?? -1
                ) ?? SettingsDefaults.historyLimit,
                retentionDays: defaults?.integer(forKey: SettingsKeys.retentionDays)
                    ?? SettingsDefaults.retentionDays,
                updatedAt: defaults?.object(forKey: SettingsKeys.historyLimitUpdatedAt) as? Date
                    ?? .distantPast
            )
            syncEnabled = defaults?.object(forKey: SettingsKeys.syncEnabled) as? Bool
                ?? SettingsDefaults.syncEnabled
            spotlightIndexing = defaults?.bool(forKey: SettingsKeys.spotlightIndexing) ?? false
            includeHistoryInBackups = defaults?.bool(forKey: SettingsKeys.includeHistoryInBackups) ?? false
            foregroundCaptureMode = IOSForegroundCaptureMode(
                rawValue: defaults?.string(forKey: IOSSettings.foregroundCaptureModeKey) ?? ""
            ) ?? .undecided
            confirmedCaptureMethods = Set(
                defaults?.stringArray(forKey: IOSSettings.confirmedCaptureMethodsKey)?
                    .compactMap(IOSCaptureMethod.init(rawValue:)) ?? []
            )
            captureSetupCompleted =
                defaults?.object(forKey: IOSSettings.captureSetupCompletedKey) as? Bool ?? false
        }
    }

    /// `defaultsMayBeUnreadable` is for a launch before the first unlock, when the defaults can
    /// read as empty: nothing is seeded over the real values until `reloadAfterDefaultsReadable()`.
    init(defaults: UserDefaults? = AppGroupContext.live()?.defaults, defaultsMayBeUnreadable: Bool = false) {
        self.defaults = defaults
        self.storageUnavailable = defaults == nil
        let stored = StoredValues(defaults: defaults)
        self.themeID = stored.themeID
        self.viewMode = stored.viewMode
        self.density = stored.density
        self.syncedHistoryLimit = stored.syncedHistoryLimit
        self.syncEnabled = stored.syncEnabled
        self.spotlightIndexing = stored.spotlightIndexing
        self.includeHistoryInBackups = stored.includeHistoryInBackups
        self.foregroundCaptureMode = stored.foregroundCaptureMode
        self.confirmedCaptureMethods = stored.confirmedCaptureMethods
        self.captureSetupCompleted = stored.captureSetupCompleted
        if !defaultsMayBeUnreadable {
            seedDefaults()
        }
    }

    /// Reads every setting again, then seeds the keys that are really absent. For a launch that
    /// started before the first unlock, once the defaults can be read.
    func reloadAfterDefaultsReadable() {
        let stored = StoredValues(defaults: defaults)
        themeID = stored.themeID
        viewMode = stored.viewMode
        density = stored.density
        syncedHistoryLimit = stored.syncedHistoryLimit
        syncEnabled = stored.syncEnabled
        spotlightIndexing = stored.spotlightIndexing
        includeHistoryInBackups = stored.includeHistoryInBackups
        foregroundCaptureMode = stored.foregroundCaptureMode
        confirmedCaptureMethods = stored.confirmedCaptureMethods
        captureSetupCompleted = stored.captureSetupCompleted
        seedDefaults()
    }

    /// Writes resolved values back when absent, so the lean `ClipStore` and extensions — which
    /// read App-Group defaults raw — see the same limit/retention the UI shows, instead of
    /// falling back to "unlimited" until Settings is first opened. Only seeds missing keys.
    private func seedDefaults() {
        guard let defaults else { return }
        if defaults.object(forKey: SettingsKeys.historyLimit) == nil {
            defaults.set(historyLimit.rawValue, forKey: SettingsKeys.historyLimit)
        }
        if defaults.object(forKey: SettingsKeys.historyLimitUpdatedAt) == nil {
            defaults.set(historyLimitUpdatedAt, forKey: SettingsKeys.historyLimitUpdatedAt)
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
        if defaults.object(forKey: SettingsKeys.spotlightIndexing) == nil {
            defaults.set(spotlightIndexing, forKey: SettingsKeys.spotlightIndexing)
        }
        if defaults.object(forKey: Self.confirmedCaptureMethodsKey) == nil {
            defaults.set([String](), forKey: Self.confirmedCaptureMethodsKey)
        }
        if defaults.object(forKey: Self.captureSetupCompletedKey) == nil {
            defaults.set(captureSetupCompleted, forKey: Self.captureSetupCompletedKey)
        }
    }

    /// A user-driven history-limit change. Announced so the sync service reconciles it.
    func setHistoryLimit(_ value: HistoryLimit) {
        guard syncedHistoryLimit.choose(value) else { return }
        NotificationCenter.default.post(name: .yankSyncedSettingsChanged, object: nil)
    }

    /// A user-driven retention change, announced like the history limit.
    func setRetentionDays(_ value: Int) {
        guard syncedHistoryLimit.chooseRetentionDays(value) else { return }
        NotificationCenter.default.post(name: .yankSyncedSettingsChanged, object: nil)
    }

    /// A history-limit change adopted from another device. Stays silent on
    /// `.yankSyncedSettingsChanged` so the value is not echoed back where it came from.
    func adoptHistoryLimit(_ settings: SyncedSettings) {
        syncedHistoryLimit.adopt(settings)
    }

    func setCaptureMethod(_ method: IOSCaptureMethod, confirmed: Bool) {
        if confirmed {
            confirmedCaptureMethods.insert(method)
        } else {
            confirmedCaptureMethods.remove(method)
        }
        if confirmedCaptureMethods.count == IOSCaptureMethod.allCases.count {
            captureSetupCompleted = true
        }
    }

    func completeCaptureSetup() {
        captureSetupCompleted = true
    }

    /// A decided privacy mode is active only after the App Group defaults accept it.
    /// Without shared defaults, remaining undecided keeps every foreground pasteboard
    /// boundary disabled rather than relying on an in-memory choice that cannot persist.
    @discardableResult
    func setForegroundCaptureMode(_ mode: IOSForegroundCaptureMode) -> Bool {
        switch mode {
        case .undecided:
            foregroundCaptureMode = .undecided
            guard let defaults else { return true }
            defaults.removeObject(forKey: Self.foregroundCaptureModeKey)
            guard defaults.object(forKey: Self.foregroundCaptureModeKey) == nil else {
                return false
            }
            return true
        case .automatic, .explicitOnly:
            guard let defaults else {
                foregroundCaptureMode = .undecided
                return false
            }
            defaults.set(mode.rawValue, forKey: Self.foregroundCaptureModeKey)
            guard defaults.string(forKey: Self.foregroundCaptureModeKey) == mode.rawValue else {
                defaults.removeObject(forKey: Self.foregroundCaptureModeKey)
                foregroundCaptureMode = .undecided
                return false
            }
            foregroundCaptureMode = mode
            return true
        }
    }

    /// A successful capture is stronger evidence than setup copy, so preserve it as confirmed.
    /// The keyboard remains user-confirmed because iOS exposes no supported way to identify Yank
    /// among the enabled third-party keyboards.
    func recordSuccessfulCaptureMethods(from sources: Set<String>) {
        var updatedMethods = confirmedCaptureMethods
        for source in sources {
            if source == Self.shareCaptureSource {
                updatedMethods.insert(.shareSheet)
            } else if Self.shortcutCaptureSources.contains(source) {
                updatedMethods.insert(.shortcut)
            }
        }
        if updatedMethods != confirmedCaptureMethods {
            confirmedCaptureMethods = updatedMethods
        }
        if !sources.isEmpty && !captureSetupCompleted {
            captureSetupCompleted = true
        }
    }

    var theme: AppTheme { AppTheme.from(id: themeID) }
}
