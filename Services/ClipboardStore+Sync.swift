import Foundation

@MainActor
extension ClipboardStore {
    func markSyncStarted() {
        syncStatus = .syncing
    }

    func markSyncSucceeded(at date: Date) {
        syncStatus = .healthy(lastSynced: date)
    }

    func markSyncFailed(_ message: String) {
        syncStatus = .failed(message: message)
    }

    func markSyncUnavailable(reason: SyncStatus.Reason) {
        syncStatus = .localOnly(reason: reason)
    }

    /// Canonical set for the sync transport: live items plus materialised tombstones.
    func itemsForSync() -> [ClipboardItem] {
        items + SyncReconcile.tombstoneItems(tombstones)
    }

    func applyReconciled(_ canonical: [ClipboardItem]) {
        let result = SyncReconcile.apply(
            canonical: canonical,
            replacing: items,
            historyLimit: maxItems,
            retentionDays: captureSettings.retentionDays,
            now: Date()
        )
        if result.cappedVisibleCount > 0 {
            Log.store.info(
                "Reconcile cap dropped \(result.cappedVisibleCount) clip(s); local limit is \(self.maxItems)."
            )
        }
        if result.expiredVisibleCount > 0 {
            Log.store.info("Reconcile retention expired \(result.expiredVisibleCount) synced clip(s).")
        }
        pendingReconciledBlobDeletions.formUnion(result.blobReferencesToDelete)
        items = result.visibleItems
        tombstones = result.tombstones
        persist(notify: result.expiredVisibleCount > 0)
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) throws {
        guard !historyWritesDisabled else { throw PersistenceError.writesDisabled }
        applyReconciled(canonical)
        try historyWriter.flush().get()
        let referencedBlobs = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) })
        let orphanedBlobs = pendingReconciledBlobDeletions.subtracting(referencedBlobs)
        blobStore.deleteBlobReferences(Array(orphanedBlobs))
        pendingReconciledBlobDeletions.removeAll()
    }

    func blobURL(for reference: SyncBlobReference) -> URL? {
        blobStore.blobURL(for: reference)
    }

    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws {
        try await blobStore.writeSyncedBlob(data, reference: reference)
    }

    func deleteBlob(_ reference: SyncBlobReference) {
        blobStore.deleteSyncedBlob(reference)
    }
}
