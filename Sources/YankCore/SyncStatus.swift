import Foundation

/// Where iCloud sync stands, for the apps to show.
public enum SyncStatus: Equatable, Sendable {
    /// Sync is not running on this device, for the given `reason`.
    case localOnly(reason: Reason)
    /// Sync is running and has not finished its current pass.
    case syncing
    /// The last sync pass finished at `lastSynced`.
    case healthy(lastSynced: Date)
    /// The last sync pass failed; `message` is one sentence a person can act on.
    case failed(message: String)

    /// Why sync is not running.
    public enum Reason: Equatable, Sendable {
        /// The user turned iCloud sync off.
        case disabled
        /// This build is not signed with the iCloud container, so sync is unavailable.
        case notProvisioned
        /// No iCloud account is signed in.
        case notAuthenticated
    }
}
