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

public extension SyncableStore {
    /// Default for stores that only offer the blocking variant.
    func applyReconciledAwaitingDurability(_ canonical: [ClipboardItem]) async throws {
        try applyReconciledDurably(canonical)
    }
}

public extension Notification.Name {
    static let yankLocalStoreDidChange = Notification.Name("yankLocalStoreDidChange")
}
