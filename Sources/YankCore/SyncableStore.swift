import Foundation

/// Store contract consumed by the CloudKit sync transport.
@MainActor
public protocol SyncableStore: AnyObject {
    /// Canonical sync snapshot: live items plus tombstones.
    func itemsForSync() -> [ClipboardItem]
    /// Apply canonical sync state in memory.
    func applyReconciled(_ canonical: [ClipboardItem])
    /// Apply canonical sync state and make the resulting snapshot durable before returning.
    /// A failure must leave the caller's remote checkpoint unchanged so the state can be retried.
    func applyReconciledDurably(_ canonical: [ClipboardItem]) throws
    /// Apply canonical sync state in memory at once, then suspend until the resulting snapshot is
    /// durable, without blocking the calling actor while the disk write finishes. The in-memory
    /// apply runs before the first suspension. A failure must leave the caller's remote
    /// checkpoint unchanged so the state can be retried.
    func applyReconciledAwaitingDurability(_ canonical: [ClipboardItem]) async throws
    /// Resolve a validated blob reference to a local file URL, if present.
    func blobURL(for reference: SyncBlobReference) -> URL?
    /// Persist blob bytes for a validated reference.
    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws
    /// Delete a local blob for a validated reference.
    func deleteBlob(_ reference: SyncBlobReference)
    /// Mark sync as actively running.
    func markSyncStarted()
    /// Mark sync as healthy at the supplied completion time.
    func markSyncSucceeded(at date: Date)
    /// Mark sync as failed with a user-facing diagnostic.
    func markSyncFailed(_ message: String)
    /// Mark sync as intentionally unavailable.
    func markSyncUnavailable(reason: SyncStatus.Reason)
    /// Mark a pull that spans several pages as running, with the number of clip records iCloud
    /// has delivered so far. The count includes edits to clips the store already holds, so it can
    /// exceed the number of clips shown. The next success, failure or stop clears it.
    func markSyncProgress(clipsReceived: Int)
    /// The transport has read the synced settings record and adopted it if it was newer. A store
    /// that holds age expiry back until then, so a stale local window cannot delete clips the
    /// user chose to keep on another device, resumes it here.
    func markSyncedSettingsRead()
    /// iCloud holds the deletes with these IDs. A store ages out its deletes past the tombstone
    /// horizon only among them: an older one iCloud has not taken yet must stay until it is pushed.
    func discardAgedTombstones(among acknowledged: Set<UUID>)
}

/// Reports the clips waiting out their undo window. They are still in the sync snapshot as live
/// clips, so sync needs to know them to keep a pulled duplicate from collapsing into one that
/// is about to be deleted. A separate protocol so `SyncableStore` stays source compatible: a
/// store that does not adopt it reports none.
@MainActor
public protocol PendingDeletionReporting: AnyObject {
    /// The IDs of the clips the user deleted that can still be undone.
    var pendingDeletionIDs: Set<UUID> { get }
}

/// Defaults for stores that do not implement these requirements themselves.
public extension SyncableStore {
    /// Default for stores that only offer the blocking variant.
    func applyReconciledAwaitingDurability(_ canonical: [ClipboardItem]) async throws {
        try applyReconciledDurably(canonical)
    }

    /// Default for stores that do not show progress.
    func markSyncProgress(clipsReceived: Int) {}

    /// Default for stores that do not hold age expiry back for the synced settings.
    func markSyncedSettingsRead() {}

    /// Default for stores that keep their deletes for good.
    func discardAgedTombstones(among acknowledged: Set<UUID>) {}
}

/// Notifications posted by the clip stores.
public extension Notification.Name {
    /// Posted when the local clip store changed, so the sync transport can push.
    static let yankLocalStoreDidChange = Notification.Name("yankLocalStoreDidChange")
}
