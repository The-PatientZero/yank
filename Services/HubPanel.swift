import Foundation

/// The data + actions for the menu-bar command panel. A plain value carrier:
/// `ClipboardController` fills it from the runtime state it owns, and `HubController`
/// renders it when the user opens the menu.
@MainActor
struct HubPrimaryPanel {
    let shortcut: String
    let shortcutOpenTarget: ShortcutOpenTarget
    let isPaused: Bool
    let ignoreNextCopyArmed: Bool
    let hotkeyUnavailable: Bool
    let itemCount: Int
    let onOpenQuickPicker: @MainActor () -> Void
    let onOpenHistory: @MainActor () -> Void
    let onTogglePause: @MainActor () -> Void
    let onIgnoreNextCopy: @MainActor () -> Void
    let onFixShortcut: @MainActor () -> Void
    let onSettings: @MainActor () -> Void
    let onClear: @MainActor () -> Void

    /// A no-op placeholder. The provider captures its owner weakly (to break the hub↔controller
    /// retain cycle), so it falls back to this only if the owner is torn down mid-render — which
    /// can't happen in practice, since the provider is cleared on `stop()` first.
    static let empty = HubPrimaryPanel(
        shortcut: "", shortcutOpenTarget: .quickPicker,
        isPaused: false, ignoreNextCopyArmed: false, hotkeyUnavailable: false,
        itemCount: 0, onOpenQuickPicker: {}, onOpenHistory: {}, onTogglePause: {}, onIgnoreNextCopy: {},
        onFixShortcut: {}, onSettings: {}, onClear: {}
    )
}
