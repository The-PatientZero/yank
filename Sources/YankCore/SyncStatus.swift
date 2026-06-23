import Foundation

public enum SyncStatus: Equatable, Sendable {
    case localOnly(reason: Reason)
    case syncing
    case healthy(lastSynced: Date)
    case failed(message: String)

    public enum Reason: Equatable, Sendable {
        case disabled
        case notProvisioned
        case notAuthenticated
    }
}
