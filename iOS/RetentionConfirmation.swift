import Foundation

/// Holds the auto-delete window awaiting confirmation while the dialog is up. Parallel to
/// `HistoryLimitConfirmation`: nothing is written until `confirm()` returns the value, so a
/// cancelled shortening can't move the window, its stamp, or sync it.
@MainActor
@Observable
final class RetentionConfirmation {
    private(set) var pending: RetentionChange.Pending?

    var isConfirming: Bool { pending != nil }

    /// Returns the window to apply immediately, or `nil` when the choice is either a no-op or now
    /// waiting on confirmation.
    func select(
        _ minutes: Int,
        current: Int,
        items: [ClipboardItem]?,
        syncEnabled: Bool,
        now: Date = Date()
    ) -> Int? {
        switch RetentionChange.requested(minutes, current: current, items: items, syncEnabled: syncEnabled, now: now) {
        case .unchanged:
            return nil
        case .apply(let minutes):
            pending = nil
            return minutes
        case .confirm(let minutes, let deleting):
            pending = RetentionChange.Pending(minutes: minutes, deleting: deleting)
            return nil
        }
    }

    /// Returns the window the user agreed to, clearing the pending state.
    func confirm() -> Int? {
        defer { pending = nil }
        return pending?.minutes
    }

    func cancel() {
        pending = nil
    }
}
