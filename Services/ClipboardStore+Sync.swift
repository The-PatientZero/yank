import Foundation

/// A waiting clip paired with the history item it stands for.
struct WaitingClipEntry: Identifiable {
    let clip: SyncWaitingClip
    let item: ClipboardItem

    var id: UUID { clip.id }
}

@MainActor
extension ClipboardStore {
    func markSyncStarted() {
        setSyncState(.syncing, failureKind: nil)
    }

    func markSyncSucceeded(at date: Date) {
        setSyncState(.healthy(lastSynced: date), failureKind: nil)
    }

    /// A failure without a known cause: the generic "Try again" action applies.
    func markSyncFailed(_ message: String) {
        setSyncState(.failed(message: message), failureKind: nil)
    }

    func markSyncFailure(_ failure: SyncFailure) {
        setSyncState(.failed(message: failure.message), failureKind: failure.kind)
    }

    func markClipsWaiting(_ clips: [SyncWaitingClip]) {
        guard clips != waitingClips else { return }
        waitingClips = clips
        NotificationCenter.default.post(name: .yankSyncStatusChanged, object: nil)
    }

    func markSyncUnavailable(reason: SyncStatus.Reason) {
        encryptionStatus = nil
        waitingClips = []
        setSyncState(.localOnly(reason: reason), failureKind: nil)
    }

    /// Puts back a state captured before a manual sync that ended without reporting anything.
    func restoreSyncState(_ status: SyncStatus, failureKind: SyncFailureKind?) {
        setSyncState(status, failureKind: failureKind)
    }

    private func setSyncState(_ status: SyncStatus, failureKind: SyncFailureKind?) {
        syncStatus = status
        syncFailureKind = failureKind
        NotificationCenter.default.post(name: .yankSyncStatusChanged, object: nil)
    }

    /// The waiting clips that still exist and are not waiting out a delete, so a delete leaves the
    /// list at once and an undo brings the clip back.
    var visibleWaitingClips: [WaitingClipEntry] {
        guard !waitingClips.isEmpty else { return [] }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pendingDeletion)
        let itemsByID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return waitingClips.compactMap { clip in
            itemsByID[clip.id].map { WaitingClipEntry(clip: clip, item: $0) }
        }
    }

    func markEncryptionStatus(_ status: SyncEncryptionStatus?) {
        encryptionStatus = status
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
