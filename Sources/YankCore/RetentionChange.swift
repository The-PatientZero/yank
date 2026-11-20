import Foundation

/// What choosing an auto-delete window should do — pure, so both platforms ask the same
/// question. Shortening the window deletes older clips on every synced device, so with sync on
/// the choice is announced even when nothing on this device is old enough: another device may
/// hold clips this one does not.
enum RetentionChange: Equatable, Sendable {
    /// A shortening waiting on the user's answer.
    struct Pending: Equatable, Sendable {
        let minutes: Int
        /// Clips this device would delete, or `nil` when they could not be counted.
        let deleting: Int?
    }

    /// Already the current window — do nothing at all, so no stamp moves and nothing is announced.
    case unchanged
    /// Safe to apply straight away.
    case apply(Int)
    /// Needs the destructive confirmation before it is applied anywhere. `deleting` is how many
    /// clips this device would delete, or `nil` when they could not be counted.
    case confirm(Int, deleting: Int?)

    /// - Parameter items: this device's clips, or `nil` when the caller has no history to
    ///   measure. Unknown falls back to confirming without a count rather than letting a
    ///   possibly destructive shortening through unannounced.
    static func requested(
        _ minutes: Int,
        current: Int,
        items: [ClipboardItem]?,
        syncEnabled: Bool,
        now: Date
    ) -> RetentionChange {
        guard minutes != current else { return .unchanged }
        let shortens = minutes > 0 && (current == 0 || minutes < current)
        guard shortens else { return .apply(minutes) }
        guard let items else { return .confirm(minutes, deleting: nil) }
        let count = ClipboardRetention.expiredItems(items, olderThanMinutes: minutes, now: now).count
        if count > 0 || syncEnabled { return .confirm(minutes, deleting: count) }
        return .apply(minutes)
    }
}
