import Foundation

/// What picking a history-limit tier should do. Pure, so both platforms' settings screens ask
/// the same question — and so the destructive branch is decided somewhere a test can reach,
/// rather than inside a view.
///
/// The rule is "would this actually delete clips?", not "is this a smaller number?": with sync
/// on, a reduction propagates to every device, so the warning has to be both unmissable when it
/// matters and absent when nothing is at stake.
public enum HistoryLimitChange: Equatable, Sendable {
    /// Already the current tier — do nothing at all, so no stamp moves and nothing is announced.
    case unchanged
    /// Safe to apply straight away: nothing would be evicted.
    case apply(HistoryLimit)
    /// Needs the destructive confirmation before it is applied anywhere.
    case confirm(HistoryLimit)

    /// - Parameter items: the clips the limit would be applied to, or `nil` when the caller has
    ///   no history to measure. Unknown falls back to the cautious tier comparison rather than
    ///   letting a possibly destructive reduction through unannounced.
    public static func requested(
        _ tier: HistoryLimit,
        current: HistoryLimit,
        items: [ClipboardItem]?
    ) -> HistoryLimitChange {
        guard tier != current else { return .unchanged }
        guard let items else {
            return tier.rawValue < current.rawValue ? .confirm(tier) : .apply(tier)
        }
        return ClipboardRetention.wouldEvict(items, limit: tier.rawValue)
            ? .confirm(tier)
            : .apply(tier)
    }
}
