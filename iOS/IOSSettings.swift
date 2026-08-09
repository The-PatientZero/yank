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

/// iOS user preferences, backed by the App-Group defaults so they survive relaunches.
/// Mirrors the slice of the Mac's `SettingsManager` that applies on iOS: accent theme,
/// layout, density, history limit, and auto-delete retention. Keys and defaults come
/// from the shared `SettingsKeys` / `SettingsDefaults`, and `ClipStore` reads the same
/// keys for limit/retention enforcement.
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
            defaults?.set(syncedHistoryLimit.updatedAt, forKey: SettingsKeys.historyLimitUpdatedAt)
        }
    }

    var historyLimit: HistoryLimit { syncedHistoryLimit.historyLimit }
    /// When the history limit was last chosen. `distantPast` means "never explicitly chosen on
    /// this device", which lets any device that has made a real choice win the first sync
    /// without silently resizing anyone's history on upgrade.
    var historyLimitUpdatedAt: Date { syncedHistoryLimit.updatedAt }
    var syncedSettings: SyncedSettings { syncedHistoryLimit.current }
    var retentionDays: Int { didSet { defaults?.set(retentionDays, forKey: SettingsKeys.retentionDays) } }
    var syncEnabled: Bool { didSet { defaults?.set(syncEnabled, forKey: SettingsKeys.syncEnabled) } }
    var spotlightIndexing: Bool { didSet { defaults?.set(spotlightIndexing, forKey: SettingsKeys.spotlightIndexing) } }
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

    init(defaults: UserDefaults? = AppGroupContext.live()?.defaults) {
        self.defaults = defaults
        self.storageUnavailable = defaults == nil
        self.themeID = defaults?.string(forKey: SettingsKeys.themeID) ?? SettingsDefaults.themeID
        self.viewMode = ClipViewMode(
            rawValue: defaults?.string(forKey: SettingsKeys.viewMode) ?? ""
        ) ?? SettingsDefaults.viewMode
        self.density = ClipDensity(
            rawValue: defaults?.string(forKey: SettingsKeys.density) ?? ""
        ) ?? SettingsDefaults.density
        self.syncedHistoryLimit = SyncedHistoryLimit(
            historyLimit: HistoryLimit(
                rawValue: defaults?.integer(forKey: SettingsKeys.historyLimit) ?? -1
            ) ?? SettingsDefaults.historyLimit,
            updatedAt: defaults?.object(forKey: SettingsKeys.historyLimitUpdatedAt) as? Date
                ?? .distantPast
        )
        self.retentionDays = defaults?.integer(forKey: SettingsKeys.retentionDays) ?? SettingsDefaults.retentionDays
        self.syncEnabled = defaults?.object(forKey: SettingsKeys.syncEnabled) as? Bool ?? SettingsDefaults.syncEnabled
        self.spotlightIndexing = defaults?.bool(forKey: SettingsKeys.spotlightIndexing) ?? false
        self.foregroundCaptureMode = IOSForegroundCaptureMode(
            rawValue: defaults?.string(forKey: Self.foregroundCaptureModeKey) ?? ""
        ) ?? .undecided
        self.confirmedCaptureMethods = Set(
            defaults?.stringArray(forKey: Self.confirmedCaptureMethodsKey)?
                .compactMap(IOSCaptureMethod.init(rawValue:)) ?? []
        )
        self.captureSetupCompleted =
            defaults?.object(forKey: Self.captureSetupCompletedKey) as? Bool ?? false
        seedDefaults()
    }

    /// Write the resolved values back when absent, so the lean `ClipStore` and the
    /// extensions — which read the App-Group defaults raw — enforce the same limit and
    /// retention the UI shows, rather than falling back to "unlimited" until the user
    /// first opens Settings. Only seeds missing keys, so it never clobbers a real choice.
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
