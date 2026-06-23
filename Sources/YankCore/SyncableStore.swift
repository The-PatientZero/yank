import Foundation

/// Store contract consumed by the CloudKit sync transport.
@MainActor
public protocol SyncableStore: AnyObject {
    /// Canonical sync snapshot: live items plus tombstones.
    func itemsForSync() -> [ClipboardItem]
    /// Apply canonical sync state in memory.
    func applyReconciled(_ canonical: [ClipboardItem])
    /// Apply canonical sync state and make the resulting snapshot durable before returning.
    func applyReconciledDurably(_ canonical: [ClipboardItem])
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

public extension Notification.Name {
    static let yankLocalStoreDidChange = Notification.Name("yankLocalStoreDidChange")
}
