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
        _ days: Int,
        current: Int,
        items: [ClipboardItem]?,
        syncEnabled: Bool,
        now: Date = Date()
    ) -> Int? {
        switch RetentionChange.requested(days, current: current, items: items, syncEnabled: syncEnabled, now: now) {
        case .unchanged:
            return nil
        case .apply(let days):
            pending = nil
            return days
        case .confirm(let days, let deleting):
            pending = RetentionChange.Pending(days: days, deleting: deleting)
            return nil
        }
    }

    /// Returns the window the user agreed to, clearing the pending state.
    func confirm() -> Int? {
        defer { pending = nil }
        return pending?.days
    }

    func cancel() {
        pending = nil
    }
}
