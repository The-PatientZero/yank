import Foundation

/// Holds the tier awaiting confirmation while the reduction dialog is up. Extracted from
/// `SettingsView` so the cancel path is unit-testable: nothing is written until `confirm()`
/// returns the tier, so a cancelled reduction can't move the value, its stamp, or sync it.
@MainActor
@Observable
final class HistoryLimitConfirmation {
    private(set) var pendingTier: HistoryLimit?

    var isConfirming: Bool { pendingTier != nil }

    /// Returns the tier to apply immediately, or `nil` when the choice is either a no-op or now
    /// waiting on confirmation.
    func select(
        _ tier: HistoryLimit,
        current: HistoryLimit,
        items: [ClipboardItem]?
    ) -> HistoryLimit? {
        switch HistoryLimitChange.requested(tier, current: current, items: items) {
        case .unchanged:
            return nil
        case .apply(let tier):
            pendingTier = nil
            return tier
        case .confirm(let tier):
            pendingTier = tier
            return nil
        }
    }

    /// Returns the tier the user agreed to, clearing the pending state.
    func confirm() -> HistoryLimit? {
        defer { pendingTier = nil }
        return pendingTier
    }

    func cancel() {
        pendingTier = nil
    }
}
