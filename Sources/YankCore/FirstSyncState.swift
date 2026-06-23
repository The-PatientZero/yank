import Foundation

/// Startup state for the first CloudKit reconciliation on an empty iOS history.
/// A Boolean can represent "settled" but cannot distinguish "still trying" from
/// "failed"; this explicit state keeps the empty-history UI honest.
enum FirstSyncState: Equatable, Sendable {
    case idle
    case syncing
    case settled
    case failed(message: String)

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
