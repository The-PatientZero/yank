import AppKit

/// What the menu-bar menu and icon need to know about sync.
struct HubSyncSummary: Equatable {
    var status: SyncStatus
    var failureKind: SyncFailureKind?
    var waitingCount: Int

    static let off = HubSyncSummary(status: .localOnly(reason: .disabled), failureKind: nil, waitingCount: 0)

    /// Sync is on and the build can reach iCloud: the menu shows the state and "Sync now".
    var isActive: Bool {
        if case .localOnly = status { return false }
        return true
    }

    var isSyncing: Bool { status == .syncing }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    var hasProblem: Bool { isFailed || waitingCount > 0 }

    /// A signed-out or restricted account will not fix itself in a few seconds, so the icon does
    /// not wait before showing it.
    var needsImmediateAttention: Bool {
        isFailed && (failureKind == .signedOut || failureKind == .accountRestricted)
    }

    var problemLine: String? {
        SyncCopy.problemLine(status: status, waitingCount: waitingCount)
    }

    /// The failure actions the menu offers besides "Sync now" (which already is "Try again").
    var offersOpenSettings: Bool {
        isFailed && SyncCopy.actions(for: failureKind).contains(.openSettings)
    }
}

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
    let isPasteSequenceActive: Bool
    let pasteSequenceItemCount: Int
    let canRepeatPasteSequence: Bool
    let sync: HubSyncSummary
    let onOpenQuickPicker: @MainActor () -> Void
    let onOpenHistory: @MainActor () -> Void
    let onTogglePasteSequence: @MainActor () -> Void
    let onRepeatPasteSequence: @MainActor (NSRunningApplication?) -> Void
    let onTogglePause: @MainActor () -> Void
    let onIgnoreNextCopy: @MainActor () -> Void
    let onFixShortcut: @MainActor () -> Void
    let onSettings: @MainActor () -> Void
    let onSyncNow: @MainActor () -> Void
    let onSyncOpenSettings: @MainActor () -> Void
    let onClear: @MainActor () -> Void

    /// A no-op placeholder. The provider captures its owner weakly (to break the hub↔controller
    /// retain cycle), so it falls back to this only if the owner is torn down mid-render — which
    /// can't happen in practice, since the provider is cleared on `stop()` first.
    static let empty = HubPrimaryPanel(
        shortcut: "", shortcutOpenTarget: .quickPicker,
        isPaused: false, ignoreNextCopyArmed: false, hotkeyUnavailable: false,
        itemCount: 0, isPasteSequenceActive: false, pasteSequenceItemCount: 0,
        canRepeatPasteSequence: false, sync: .off,
        onOpenQuickPicker: {}, onOpenHistory: {}, onTogglePasteSequence: {},
        onRepeatPasteSequence: { _ in },
        onTogglePause: {}, onIgnoreNextCopy: {},
        onFixShortcut: {}, onSettings: {}, onSyncNow: {}, onSyncOpenSettings: {}, onClear: {}
    )
}
