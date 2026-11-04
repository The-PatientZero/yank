import Foundation

/// Where the move to end-to-end encrypted clip content stands on this account, as the sync
/// transport last worked it out. Shown next to the sync status in Settings.
public enum SyncEncryptionStatus: Equatable, Sendable {
    /// Readable copies are still written next to the encrypted ones, so older Yank builds keep
    /// working. `earliestCompletion` is the first day the switch can happen; `olderDeviceLastSeen`
    /// is when activity from a build that does not read the encrypted copy was last noticed.
    case finishing(earliestCompletion: Date?, olderDeviceLastSeen: Date?)
    /// Encrypted-only writing is on and the readable copies already in iCloud are being erased.
    case removingReadableCopies
    /// No readable clip content is left in iCloud.
    case complete
    /// A device on an older build put a readable copy back, or cannot show new clips.
    case olderDeviceSeen(lastSeen: Date)
}

/// Receives the encryption status from the sync transport. A separate protocol so
/// `SyncableStore` stays source compatible.
@MainActor
public protocol SyncEncryptionStatusReporting: AnyObject {
    /// Records the latest encryption status; nil means none is known.
    func markEncryptionStatus(_ status: SyncEncryptionStatus?)
}
