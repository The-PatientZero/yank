import Foundation
import ServiceManagement
import Observation

// Shared setting model types keep macOS and iOS preference values aligned.

enum HistoryWindowPlacement: String, CaseIterable, Hashable, Identifiable, Sendable {
    case menuBarIcon
    case lastPosition
    case center
    case topRight

    var id: String { rawValue }
}

enum HistoryWindowPlacementDefaults {
    static func initialPlacement(storedRawValue: String?) -> HistoryWindowPlacement {
        guard let storedRawValue,
              let placement = HistoryWindowPlacement(rawValue: storedRawValue) else {
            return .menuBarIcon
        }
        return placement
    }
}

enum QuickPickerPlacement: String, CaseIterable, Hashable, Identifiable, Sendable {
    case focusedInput
    case menuBarIcon
    case lastPosition
    case center
    case topRight

    var id: String { rawValue }
}

enum QuickPickerPlacementDefaults {
    static func initialPlacement(storedRawValue: String?) -> QuickPickerPlacement {
        guard let storedRawValue,
              let placement = QuickPickerPlacement(rawValue: storedRawValue) else {
            return .focusedInput
        }
        return placement
    }
}

enum ShortcutOpenTarget: String, CaseIterable, Hashable, Identifiable, Sendable {
    case quickPicker
    case fullHistory

    var id: String { rawValue }
}

enum ShortcutOpenTargetDefaults {
    static func initialTarget(storedRawValue: String?) -> ShortcutOpenTarget {
        guard let storedRawValue,
              let target = ShortcutOpenTarget(rawValue: storedRawValue) else {
            return .quickPicker
        }
        return target
    }
}

/// Manages user preferences for Yank
@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults.standard
    
    // macOS-only keys. The cross-platform keys (themeID / clipViewMode / clipDensity /
    // historyLimit / retentionDays) live in the shared `SettingsKeys`.
    private let hotkeyModifiersKey = "hotkeyModifiers"
    private let hotkeyKeyCodeKey = "hotkeyKeyCode"
    private let excludedBundleIDsKey = "excludedBundleIDs"
    private let minCaptureLengthKey = "minCaptureLength"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let keepHistoryWindowOpenKey = "keepHistoryWindowOpen"
    private let aiTaggingEnabledKey = "aiTaggingEnabled"
    private let historyWindowPlacementKey = "historyWindowPlacement"
    private let quickPickerPlacementKey = "quickPickerPlacement"
    private let shortcutOpenTargetKey = "shortcutOpenTarget"
    private let clickToPasteInQuickViewsKey = "clickToPasteInQuickViews"
    private let hapticFeedbackKey = "hapticFeedback"
    private let soundEffectsKey = "soundEffects"
    private let soundEffectChoiceKey = "soundEffectChoice"

    var hotkeyModifiers: HotkeyModifiers
    var hotkeyKeyCode: UInt16

    var launchAtLogin: Bool = false

    /// Value plus stamp in one place, so the limit can never move without its stamp. The
    /// choose-versus-adopt rule lives in `SyncedHistoryLimit` and is shared with iOS.
    private var syncedHistoryLimit = SyncedHistoryLimit(historyLimit: SettingsDefaults.historyLimit)

    var historyLimit: HistoryLimit { syncedHistoryLimit.historyLimit }
    /// When the history limit was last chosen. `distantPast` means "never explicitly chosen on
    /// this device", which lets any device that has made a real choice win the first sync
    /// without silently resizing anyone's history on upgrade.
    var historyLimitUpdatedAt: Date { syncedHistoryLimit.updatedAt }
    var syncedSettings: SyncedSettings { syncedHistoryLimit.current }

    /// Apps whose copies are never captured. Bundle identifiers.
    var excludedBundleIDs: Set<String> = []

    /// Copies whose trimmed length is below this are never captured (0 = off).
    var minCaptureLength: Int = 0

    /// Auto-delete window in days (0 = keep forever). Synced: expiry mints tombstones that
    /// propagate, so the window must be one account-wide choice.
    var retentionDays: Int { syncedHistoryLimit.current.retentionDays ?? SettingsDefaults.retentionDays }

    /// Whether the menu-bar icon is shown (the global hotkey works regardless).
    var showMenuBarIcon: Bool = true

    /// Whether outside clicks leave the history window visible.
    var keepHistoryWindowOpen: Bool = false

    /// On-device AI tag suggestions for new text clips. Off by default — opt-in.
    var aiTaggingEnabled: Bool = false

    /// Where the history window opens before the user drags it somewhere custom.
    var historyWindowPlacement: HistoryWindowPlacement = .menuBarIcon
    var quickPickerPlacement: QuickPickerPlacement = .focusedInput
    var shortcutOpenTarget: ShortcutOpenTarget = .quickPicker

    var clickToPasteInQuickViews: Bool = true

    /// Trackpad haptic feedback on key actions (copy, paste, pin, delete). On by default — it is
    /// subtle, private, and the signature premium touch; a no-op on Macs without a Force Touch
    /// trackpad.
    var hapticFeedbackEnabled: Bool = true

    /// Subtle sound cues on copy and paste. Off by default — audible feedback is public and
    /// polarizing, so it stays opt-in.
    var soundEffectsEnabled: Bool = false
    var soundEffectChoice: SoundEffectChoice = .defaultChoice

    /// Whether captured clips are pushed into system-wide Core Spotlight. Off by default —
    /// clipboard history can hold secrets, so system-wide indexing is opt-in.
    var spotlightIndexingEnabled: Bool = false
    var syncEnabled: Bool = SettingsDefaults.syncEnabled

    /// Accent theme id (see `AppTheme`).
    var themeID: String = SettingsDefaults.themeID

    /// How the clip stream is laid out.
    var viewMode: ClipViewMode = SettingsDefaults.viewMode

    /// How much breathing room each clip gets.
    var density: ClipDensity = SettingsDefaults.density

    /// Snapshot of just the settings the capture path needs. The composition
    /// root injects this into `ClipboardStore` / `ClipboardWatcher` at construction and
    /// re-pushes it when the user changes a relevant setting, so capture logic depends on
    /// an injected value rather than this singleton.
    var captureSettings: CaptureSettings {
        CaptureSettings(
            historyLimit: historyLimit.rawValue,
            retentionDays: retentionDays,
            minCaptureLength: minCaptureLength,
            excludedBundleIDs: excludedBundleIDs
        )
    }

    var feedbackSettings: FeedbackSettings {
        FeedbackSettings(
            soundEffectsEnabled: soundEffectsEnabled,
            hapticFeedbackEnabled: hapticFeedbackEnabled,
            soundEffectChoice: soundEffectChoice
        )
    }

    private init() {
        let defaultMods = HotkeyModifiers(shift: true, command: true, option: false, control: false)
        let defaultKeyCode: UInt16 = 9  // V key
        
        if let savedMods = defaults.array(forKey: hotkeyModifiersKey) as? [String] {
            self.hotkeyModifiers = HotkeyModifiers(from: savedMods)
        } else {
            self.hotkeyModifiers = defaultMods
        }
        
        let savedKeyCode = defaults.integer(forKey: hotkeyKeyCodeKey)
        self.hotkeyKeyCode = savedKeyCode > 0 ? UInt16(savedKeyCode) : defaultKeyCode

        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        
        let rawLimit = defaults.integer(forKey: SettingsKeys.historyLimit)
        self.syncedHistoryLimit = SyncedHistoryLimit(
            historyLimit: HistoryLimit(rawValue: rawLimit) ?? SettingsDefaults.historyLimit,
            retentionDays: defaults.integer(forKey: SettingsKeys.retentionDays),
            updatedAt: defaults.object(forKey: SettingsKeys.historyLimitUpdatedAt) as? Date
                ?? .distantPast
        )

        if defaults.object(forKey: excludedBundleIDsKey) == nil {
            self.excludedBundleIDs = Set(suggestedExclusions.map(\.bundleID))
            defaults.set(Array(excludedBundleIDs).sorted(), forKey: excludedBundleIDsKey)
        } else {
            self.excludedBundleIDs = Set(defaults.stringArray(forKey: excludedBundleIDsKey) ?? [])
        }
        self.minCaptureLength = defaults.integer(forKey: minCaptureLengthKey)
        self.showMenuBarIcon = defaults.object(forKey: showMenuBarIconKey) as? Bool ?? true
        self.keepHistoryWindowOpen = defaults.object(forKey: keepHistoryWindowOpenKey) as? Bool ?? false
        self.aiTaggingEnabled = defaults.bool(forKey: aiTaggingEnabledKey)
        self.historyWindowPlacement = HistoryWindowPlacementDefaults.initialPlacement(
            storedRawValue: defaults.string(forKey: historyWindowPlacementKey)
        )
        self.quickPickerPlacement = QuickPickerPlacementDefaults.initialPlacement(
            storedRawValue: defaults.string(forKey: quickPickerPlacementKey)
        )
        self.shortcutOpenTarget = ShortcutOpenTargetDefaults.initialTarget(
            storedRawValue: defaults.string(forKey: shortcutOpenTargetKey)
        )
        self.clickToPasteInQuickViews =
            defaults.object(forKey: clickToPasteInQuickViewsKey) as? Bool ?? true
        self.hapticFeedbackEnabled = defaults.object(forKey: hapticFeedbackKey) as? Bool ?? true
        self.soundEffectsEnabled = defaults.object(forKey: soundEffectsKey) as? Bool ?? false
        self.soundEffectChoice =
            SoundEffectChoice(rawValue: defaults.string(forKey: soundEffectChoiceKey) ?? "")
            ?? .defaultChoice
        self.spotlightIndexingEnabled = defaults.bool(forKey: SettingsKeys.spotlightIndexing)
        self.syncEnabled = defaults.object(forKey: SettingsKeys.syncEnabled) as? Bool ?? SettingsDefaults.syncEnabled
        self.themeID = defaults.string(forKey: SettingsKeys.themeID) ?? SettingsDefaults.themeID
        self.viewMode = ClipViewMode(rawValue: defaults.string(forKey: SettingsKeys.viewMode) ?? "") ?? SettingsDefaults.viewMode
        self.density = ClipDensity(rawValue: defaults.string(forKey: SettingsKeys.density) ?? "") ?? SettingsDefaults.density
    }

    func save() {
        defaults.set(hotkeyModifiers.toArray(), forKey: hotkeyModifiersKey)
        defaults.set(Int(hotkeyKeyCode), forKey: hotkeyKeyCodeKey)
        defaults.set(historyLimit.rawValue, forKey: SettingsKeys.historyLimit)
        defaults.set(historyLimitUpdatedAt, forKey: SettingsKeys.historyLimitUpdatedAt)
        defaults.set(Array(excludedBundleIDs).sorted(), forKey: excludedBundleIDsKey)
        defaults.set(minCaptureLength, forKey: minCaptureLengthKey)
        defaults.set(retentionDays, forKey: SettingsKeys.retentionDays)
        defaults.set(showMenuBarIcon, forKey: showMenuBarIconKey)
        defaults.set(keepHistoryWindowOpen, forKey: keepHistoryWindowOpenKey)
        defaults.set(aiTaggingEnabled, forKey: aiTaggingEnabledKey)
        defaults.set(historyWindowPlacement.rawValue, forKey: historyWindowPlacementKey)
        defaults.set(quickPickerPlacement.rawValue, forKey: quickPickerPlacementKey)
        defaults.set(shortcutOpenTarget.rawValue, forKey: shortcutOpenTargetKey)
        defaults.set(clickToPasteInQuickViews, forKey: clickToPasteInQuickViewsKey)
        defaults.set(hapticFeedbackEnabled, forKey: hapticFeedbackKey)
        defaults.set(soundEffectsEnabled, forKey: soundEffectsKey)
        defaults.set(soundEffectChoice.rawValue, forKey: soundEffectChoiceKey)
        defaults.set(spotlightIndexingEnabled, forKey: SettingsKeys.spotlightIndexing)
        defaults.set(syncEnabled, forKey: SettingsKeys.syncEnabled)
        defaults.set(themeID, forKey: SettingsKeys.themeID)
        defaults.set(viewMode.rawValue, forKey: SettingsKeys.viewMode)
        defaults.set(density.rawValue, forKey: SettingsKeys.density)
        // Posting on every save is fine: the store's `captureSettings` setter no-ops
        // when the capture-relevant fields are unchanged.
        NotificationCenter.default.post(name: .yankCaptureSettingsChanged, object: nil)
    }

    // Each setter pairs a write with the exact notification its call site posts today, so the
    // two can't drift apart. The notification mapping is preserved verbatim from `SettingsView`.

    func setShowMenuBarIcon(_ value: Bool) {
        showMenuBarIcon = value
        save()
        NotificationCenter.default.post(name: .yankMenuBarVisibilityChanged, object: nil)
    }

    func setSpotlightIndexingEnabled(_ value: Bool) {
        spotlightIndexingEnabled = value
        save()
        NotificationCenter.default.post(name: .yankSpotlightIndexingChanged, object: nil)
    }

    func setAITaggingEnabled(_ value: Bool) {
        aiTaggingEnabled = value
        save()
        NotificationCenter.default.post(name: .yankAITaggingChanged, object: nil)
    }

    /// A user-driven history-limit change. Announced so the sync service reconciles it.
    func setHistoryLimit(_ value: HistoryLimit) {
        guard syncedHistoryLimit.choose(value) else { return }
        save()
        NotificationCenter.default.post(name: .yankSyncedSettingsChanged, object: nil)
    }

    /// A user-driven retention change, announced like the history limit.
    func setRetentionDays(_ value: Int) {
        guard syncedHistoryLimit.chooseRetentionDays(value) else { return }
        save()
        NotificationCenter.default.post(name: .yankSyncedSettingsChanged, object: nil)
    }

    /// A history-limit change adopted from another device. Stays silent on
    /// `.yankSyncedSettingsChanged` so the value is not echoed back where it came from.
    /// `save()` still posts `.yankCaptureSettingsChanged`, which is what re-applies retention.
    func adoptHistoryLimit(_ settings: SyncedSettings) {
        syncedHistoryLimit.adopt(settings)
        save()
    }

    func setSyncEnabled(_ value: Bool) {
        syncEnabled = value
        save()
        NotificationCenter.default.post(name: .yankSyncPreferenceChanged, object: nil)
    }

    func setThemeID(_ value: String) {
        themeID = value
        save()
        NotificationCenter.default.post(name: .yankThemeChanged, object: nil)
    }

    func setViewMode(_ value: ClipViewMode) {
        viewMode = value
        save()
        NotificationCenter.default.post(name: .yankAppearanceChanged, object: nil)
    }

    func setDensity(_ value: ClipDensity) {
        density = value
        save()
        NotificationCenter.default.post(name: .yankAppearanceChanged, object: nil)
    }

    func setHotkey(keyCode: UInt16, modifiers: HotkeyModifiers) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        save()
        NotificationCenter.default.post(name: .yankHotkeyChanged, object: nil)
    }

    func setExclusion(bundleID: String, enabled: Bool) {
        guard !bundleID.isEmpty else { return }
        if enabled {
            excludedBundleIDs.insert(bundleID)
        } else {
            excludedBundleIDs.remove(bundleID)
        }
        save()
    }
    
    func toggleLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered { return nil }
                try SMAppService.mainApp.unregister()
            }
            self.launchAtLogin = enabled
            return nil
        } catch {
            Log.app.error("Failed to toggle Launch at Login: \(error.localizedDescription)")
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
            return error.localizedDescription
        }
    }
}

/// A password-manager (or similar) app suggested for the capture-exclusion list.
struct AppExclusionSuggestion: Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Curated, opt-in exclusion suggestions. Users review before enabling and
/// can add any other app from disk, so the list stays small and high-confidence.
let suggestedExclusions: [AppExclusionSuggestion] = [
    AppExclusionSuggestion(bundleID: "com.apple.Passwords", name: "Passwords"),
    AppExclusionSuggestion(bundleID: "com.1password.1password", name: "1Password"),
    AppExclusionSuggestion(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
    AppExclusionSuggestion(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
    AppExclusionSuggestion(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC")
]

/// Represents hotkey modifier keys
struct HotkeyModifiers: Equatable {
    var shift: Bool
    var command: Bool
    var option: Bool
    var control: Bool
    
    init(shift: Bool = false, command: Bool = false, option: Bool = false, control: Bool = false) {
        self.shift = shift
        self.command = command
        self.option = option
        self.control = control
    }
    
    init(from array: [String]) {
        self.shift = array.contains("shift")
        self.command = array.contains("command")
        self.option = array.contains("option")
        self.control = array.contains("control")
    }
    
    func toArray() -> [String] {
        var result: [String] = []
        if shift { result.append("shift") }
        if command { result.append("command") }
        if option { result.append("option") }
        if control { result.append("control") }
        return result
    }
    
    var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }
}

/// Map key codes to display names
let keyCodeNames: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
    32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
    41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
    49: "Space", 50: "`",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
]
