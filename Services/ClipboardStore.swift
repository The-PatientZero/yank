import Foundation
import AppKit
import Observation

/// Manages persistent storage of clipboard history
@MainActor
@Observable
final class ClipboardStore {
    enum PersistenceError: LocalizedError {
        case writesDisabled

        var errorDescription: String? {
            "History writes are disabled because the saved snapshot could not be loaded."
        }
    }

    var items: [ClipboardItem] = [] {
        didSet {
            filterCache.invalidate()
            cachedTags = ClipboardMutations.allTags(items)
            changeToken &+= 1
        }
    }

    /// Injected capture-relevant settings — replaces reading `SettingsManager.shared` on the
    /// capture critical path so the store is testable in isolation. The composition root
    /// re-assigns this when the user changes the history limit or retention window.
    var captureSettings: CaptureSettings {
        didSet {
            guard captureSettings != oldValue else { return }
            // A tighter limit / shorter window may now evict items; re-apply on change so
            // the live history honours the new bounds without waiting for the next capture.
            pruneExpired()
        }
    }

    /// False until the first on-disk load completes, so the history window can tell a
    /// genuinely empty clipboard apart from one that simply hasn't hydrated yet — and
    /// never flash a false "clear" empty state over a populated history on cold open.
    private(set) var hasLoaded = false

    /// True when the on-disk storage directory could not be created (sandbox / odd-volume
    /// edge), so history cannot be persisted this session and any captures will be lost on
    /// quit. Surfaced for the UI to warn the user; never silently swallowed.
    private(set) var storageUnavailable = false

    var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)

    /// Why sync is in its failed state, when the sync service could tell; nil for any other state.
    var syncFailureKind: SyncFailureKind?

    /// Clips the last push could not prepare for upload. Read through `visibleWaitingClips`.
    var waitingClips: [SyncWaitingClip] = []

    /// How far the move to end-to-end encrypted clip content has come; nil until sync reports it.
    var encryptionStatus: SyncEncryptionStatus?

    @ObservationIgnored var tombstones: [UUID: Date] = [:]
    @ObservationIgnored var historyWritesDisabled = false
    /// Blobs that no clip references any more, kept until the snapshot that stopped referencing
    /// them is durable (a sync reconcile, a delete, a clear, retention or the history cap). A
    /// failed write leaves them here for the next successful save, so the last durable snapshot
    /// never points at deleted content.
    @ObservationIgnored var blobDeletionsAwaitingSnapshot: Set<ClipboardBlobReference> = []

    /// The newest scheduled snapshot write. A sync pull that changed nothing still waits for it,
    /// and retries it if it failed, so it never reports success over a state that is not on disk.
    @ObservationIgnored var latestHistoryWriteReceipt: HistorySnapshotWriteReceipt?

    /// Bumped whenever the watcher's consecutive-repeat suppression must start over: a delete is
    /// enqueued, history is cleared, or a capture was not saved. The watcher compares it with the
    /// value it recorded, so a user who deletes a clip and copies the same text again keeps the copy.
    @ObservationIgnored private(set) var captureResetRevision = 0

    var pendingDeletion: PendingDeletion? {
        didSet { filterCache.invalidate() }
    }

    /// Bumped on every `items` mutation so views can observe "something changed" with an
    /// O(1) integer compare instead of diffing the whole array each time.
    private(set) var changeToken = 0

    /// Memoised filtered/sorted view of `items`; invalidated whenever `items` changes
    /// (see `filteredItems`). Keeps the window's per-render recomputation O(1) on a hit.
    @ObservationIgnored var filterCache = ClipFilterCache()

    /// Per-id memo of file sizes. Clipboard blobs are immutable for a stable item id.
    @ObservationIgnored var sizeCache: [UUID: Int] = [:]

    /// Memoised `allTags`, recomputed in `items.didSet` rather than on every read. Views
    /// (the tag chip bar / filter menu) read `allTags` several times per render and
    /// keystroke, and the source list does not change between renders.
    @ObservationIgnored var cachedTags: [String] = []

    var maxItems: Int { captureSettings.historyLimit }

    /// History elements this build cannot read (for example written by another version). They
    /// are written back unchanged on every save and their files are never deleted. Observed so
    /// the history window can tell the user.
    var heldElements: [HeldHistoryElement] = [] {
        didSet { blobStore.protectedFilenames = Set(heldElements.flatMap(\.filenames)) }
    }

    var heldClipCount: Int { heldElements.count }

    /// All on-disk blob storage is delegated here — see `ClipBlobStore`.
    @ObservationIgnored let blobStore: ClipBlobStore

    /// When capture-path age retention last ran. Age-based expiry is coarse and time-driven, so
    /// running it every capture is wasted work — gated to at most once per `expirySweepInterval`.
    /// Explicit triggers (settings change, retention notification, launch) bypass the gate.
    @ObservationIgnored private var lastExpirySweep: Date = .distantPast

    /// Minimum spacing between capture-path expiry sweeps. Retention is a day-granularity
    /// policy, so a one-minute floor is imperceptible while collapsing a burst of captures
    /// from N linear passes down to one.
    private static let expirySweepInterval: TimeInterval = 60

    /// Coalesces a burst of mutations (auto-capture, pin/tag) into a single trailing write
    /// instead of re-encoding the whole history per change. Shared with the iOS store.
    @ObservationIgnored lazy var historyWriter = HistorySnapshotWriter(
        historyURL: historyFileURL,
        tombstonesURL: tombstonesFileURL,
        writeOptions: ClipBlobStore.writeOptions,
        filePermissions: ClipBlobStore.filePermissions,
        fileProtection: ClipBlobStore.fileProtection,
        debounce: .milliseconds(300),
        queueLabel: "com.yank.save",
        onError: { error in Log.store.error("Failed to save history: \(error.localizedDescription)") }
    )

    private var historyFileURL: URL {
        blobStore.storageDirectory.appendingPathComponent("history.json")
    }

    private var tombstonesFileURL: URL {
        blobStore.storageDirectory.appendingPathComponent("tombstones.json")
    }

    /// True from `init(deferHistoryLoad: true)` until `hydrate()` has applied the saved history.
    /// While it is set nothing may write the history file or apply synced state: an empty
    /// in-memory list must never replace the unloaded file.
    @ObservationIgnored private(set) var isHistoryLoadPending = false

    @ObservationIgnored private var hydrateTask: Task<Void, Never>?

    /// With `deferHistoryLoad` the saved history is not read here: call `hydrate()` and wait for
    /// it before anything captures, syncs or shows the history. The app does this so the load
    /// does not block launch; the default keeps the synchronous load for every other caller.
    init(settings: CaptureSettings, storageDirectory: URL? = nil, deferHistoryLoad: Bool = false) {
        self.captureSettings = settings
        self.blobStore = ClipBlobStore(storageDirectoryOverride: storageDirectory)
        if !blobStore.ensureDirectoriesExist() {
            storageUnavailable = true
        }
        if deferHistoryLoad {
            isHistoryLoadPending = true
            return
        }
        applyLoadResult(HistorySnapshotLoader.load(historyURL: historyFileURL, tombstonesURL: tombstonesFileURL))
        finishLaunchLoad()
    }

    /// Reads the saved history off the main thread, then applies it and does the launch work
    /// that follows a load. Concurrent and repeated callers share one load.
    func hydrate() async {
        if let hydrateTask {
            await hydrateTask.value
            return
        }
        guard isHistoryLoadPending else { return }
        let historyURL = historyFileURL
        let tombstonesURL = tombstonesFileURL
        let task = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                HistorySnapshotLoader.load(historyURL: historyURL, tombstonesURL: tombstonesURL)
            }.value
            // Cleared first, so everything below that persists is not swallowed by the guard.
            self.isHistoryLoadPending = false
            self.applyLoadResult(result)
            self.finishLaunchLoad()
        }
        hydrateTask = task
        await task.value
    }

    /// Apply age retention and the cap, sweep orphaned blobs, and mark the history ready.
    private func finishLaunchLoad() {
        pruneExpired()
        sweepOrphanedBlobsAtLaunch()
        hasLoaded = true
    }

    /// Apply age retention, the local history cap, and tombstone pruning. Explicit calls
    /// (launch, `captureSettings` change) bypass the capture-path time gate.
    func pruneExpired() {
        if applyRetentionAndLimit(now: Date()) { persist() }
    }

    /// One-shot sweep for blob files a reconcile's deferred delete missed — a crash between the
    /// durable flush and the file delete leaves them behind for good. Runs in `init`, before the
    /// watcher or sync can write a blob, so an in-flight capture can never look orphaned.
    private func sweepOrphanedBlobsAtLaunch() {
        guard let present = blobStore.allBlobReferences() else { return }
        let referenced = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) })
        let orphaned = present.subtracting(referenced)
        guard !orphaned.isEmpty else { return }
        blobStore.deleteBlobReferences(Array(orphaned))
        Log.store.info("Removed \(orphaned.count) orphaned blob file(s) at launch.")
    }

    // MARK: - Public API

    /// Returns whether the capture was saved (or merged into an existing clip). `false` means
    /// nothing durable changed, so the caller must not treat the content as applied.
    @discardableResult
    func add(
        _ item: ClipboardItem,
        richArchive: PasteboardArchive? = nil,
        observedAt: Date? = nil
    ) -> Bool {
        guard !isHistoryLoadPending else { return reportCaptureResult(saved: false) }
        var stamped = stampOrigin(on: item)
        guard !refreshDuplicateIfPresent(stamped, observedAt: observedAt) else {
            return reportCaptureResult(saved: !historyWritesDisabled)
        }

        // Persist the full pasteboard archive only now that we know the item is being
        // inserted (not deduped) — so a rejected copy never orphans a rich file.
        if let archive = richArchive, let filename = saveRichArchive(archive) {
            stamped.richFilename = filename
        }
        insert(stamped, observedAt: observedAt)
        return reportCaptureResult(saved: !historyWritesDisabled)
    }

    /// Capture-specific insertion boundary. Duplicate resolution runs on the main actor before any
    /// filesystem work; encoding/writes then run on a utility executor and cancellation removes
    /// every newly written file. The caller's serial capture queue keeps final mutations FIFO.
    /// Returns whether the capture was saved (or merged into an existing clip).
    @discardableResult
    func addCaptured(
        _ item: ClipboardItem,
        primaryBlob: ClipboardCapturePrimaryBlob?,
        richArchive: PasteboardArchive?,
        observedAt: Date? = nil
    ) async -> Bool {
        await hydrate()
        var stamped = stampOrigin(on: item)
        if primaryBlob == nil, refreshDuplicateIfPresent(stamped, observedAt: observedAt) {
            return reportCaptureResult(saved: !historyWritesDisabled)
        }

        if primaryBlob != nil || richArchive != nil {
            guard let persisted = await blobStore.persistCaptureBlobs(
                primary: primaryBlob,
                richArchive: richArchive
            ) else {
                return reportCaptureResult(saved: false)
            }
            guard !Task.isCancelled else {
                await blobStore.discardCaptureBlobs(persisted)
                return reportCaptureResult(saved: false)
            }
            stamped = applying(persisted, to: stamped)
        }

        insert(stamped, observedAt: observedAt)
        return reportCaptureResult(saved: !historyWritesDisabled)
    }

    private func reportCaptureResult(saved: Bool) -> Bool {
        if !saved { captureResetRevision += 1 }
        return saved
    }

    /// Restarts the watcher's consecutive-repeat suppression (delete enqueued, history cleared).
    func resetCaptureSuppression() {
        captureResetRevision += 1
    }

    private func stampOrigin(on item: ClipboardItem) -> ClipboardItem {
        var stamped = item
        if stamped.deviceOrigin.isEmpty { stamped.deviceOrigin = DeviceIdentity.current }
        return stamped
    }

    private func refreshDuplicateIfPresent(_ item: ClipboardItem, observedAt: Date?) -> Bool {
        // Collapse only complete, plain, byte-identical inline text. Refresh the newest
        // matching capture while retaining its stable identity and annotations; older
        // pre-existing duplicates remain untouched for forward-compatible history handling.
        // A clip waiting out its undo window is not a match: the fresh copy must outlive it.
        let pendingIDs = pendingDeletionIDs
        guard case .refresh(let existingID) = DuplicateCaptureDecision.decide(
            for: item,
            in: items,
            excluding: pendingIDs
        ) else {
            return false
        }
        _ = ClipboardMutations.refreshDuplicateCapture(
            existingID: existingID,
            with: item,
            in: &items
        )
        persist()
        signalCapture(observedAt: observedAt)   // a re-copy still confirms — the user pressed ⌘C
        return true
    }

    private func applying(
        _ persisted: PersistedClipboardCaptureBlobs,
        to item: ClipboardItem
    ) -> ClipboardItem {
        ClipboardItem(
            id: item.id,
            type: item.type,
            timestamp: item.timestamp,
            sourceApp: item.sourceApp,
            textContent: item.textContent,
            textFilename: persisted.primaryKind == .text
                ? persisted.primaryFilename
                : item.textFilename,
            imageFilename: persisted.primaryKind == .image
                ? persisted.primaryFilename
                : item.imageFilename,
            richFilename: persisted.richFilename ?? item.richFilename,
            hasRichContent: item.hasRichContent,
            isPinned: item.isPinned,
            isBookmarked: item.isBookmarked,
            tags: item.tags,
            ocrText: item.ocrText,
            isTruncated: item.isTruncated,
            originalSizeBytes: item.originalSizeBytes,
            searchIndex: item.searchIndex,
            aiTags: item.aiTags,
            aiTitle: item.aiTitle,
            aiEnrichedAt: item.aiEnrichedAt,
            modifiedAt: item.modifiedAt,
            deletedAt: item.deletedAt,
            deviceOrigin: item.deviceOrigin,
            annotationClocks: item.annotationClocks
        )
    }

    private func insert(_ item: ClipboardItem, observedAt: Date?) {
        tombstones.removeValue(forKey: item.id)
        items.insert(item, at: 0)

        _ = applyHistoryLimit()

        _ = sweepExpiredOnCapture(now: Date())
        persist()
        signalCapture(observedAt: observedAt)
    }

    /// Fan a capture out to every confirmation channel: the non-visual `Feedback` cue (haptic +
    /// sound) and the view-layer pulse signal the menu-bar glyph observes. The single capture
    /// acknowledgement point — both `add` exit paths route through it.
    private func signalCapture(observedAt: Date?) {
        Feedback.emit(
            .capture,
            allowsSound: CaptureFeedbackPolicy.allowsSound(observedAt: observedAt)
        )
        NotificationCenter.default.post(name: .yankDidCapture, object: nil)
    }

    // MARK: - Private

    private func applyLoadResult(_ result: Result<HistorySnapshotLoader.Snapshot, HistorySnapshotLoader.LoadError>) {
        switch result {
        case .success(let snapshot):
            // Nothing may change the history before it is loaded, so this replaces an empty state.
            assert(items.isEmpty && tombstones.isEmpty, "History changed before it finished loading.")
            items = snapshot.items
            tombstones = snapshot.tombstones
            heldElements = snapshot.heldElements
        case .failure(let error):
            storageUnavailable = true
            historyWritesDisabled = true
            Log.store.error("Failed to load history snapshot: \(error.localizedDescription)")
        }
    }

    func blobURL(for item: ClipboardItem) -> URL? {
        blobStore.blobURL(for: item)
    }

    @discardableResult
    private func applyHistoryLimit() -> Bool {
        guard maxItems > 0, items.count > maxItems else { return false }
        let result = ClipboardRetention.cap(items, limit: maxItems)
        guard result.items != items else { return false }
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
        items = result.items
        return true
    }

    @discardableResult
    private func applyRetentionAndLimit(now: Date) -> Bool {
        let result = ClipboardRetention.enforce(
            items: items,
            tombstones: tombstones,
            historyLimit: maxItems,
            retentionDays: captureSettings.retentionDays,
            now: now
        )
        guard result.didChange else { return false }
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
        items = result.items
        tombstones = result.tombstones
        return true
    }

    @discardableResult
    private func sweepExpiredOnCapture(now: Date) -> Bool {
        if now.timeIntervalSince(lastExpirySweep) < Self.expirySweepInterval {
            return false
        }
        lastExpirySweep = now
        return applyRetentionAndLimit(now: now)
    }

    /// Merge freshly-minted tombstones into the live map. Centralised so every removal
    /// path records them identically.
    func recordTombstones(_ newTombstones: [UUID: Date]) {
        for (id, date) in newTombstones {
            tombstones[id] = date
        }
    }

    /// Stop keeping an element once a readable clip or a newer deletion record supersedes it, so a
    /// kept copy never doubles a live clip or brings back a deleted one.
    private func releaseHeldElements() {
        let kept = HeldHistoryElement.kept(
            heldElements,
            tombstones: tombstones,
            liveIDs: Set(items.map(\.id))
        )
        if kept != heldElements { heldElements = kept }
    }

    /// Returns the receipt of the scheduled write, or nil when writes are disabled.
    @discardableResult
    func persist(notify: Bool = true) -> HistorySnapshotWriteReceipt? {
        guard !historyWritesDisabled, !isHistoryLoadPending else {
            Log.store.error("Skipped history save because the on-disk snapshot has not loaded.")
            return nil
        }
        releaseHeldElements()
        let receipt = historyWriter.scheduleSave(
            items: items,
            preservedElements: heldElements,
            tombstones: tombstones
        )
        latestHistoryWriteReceipt = receipt
        releaseBlobsOnceDurable(after: receipt)
        if notify {
            NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: self)
        }
        return receipt
    }

    /// Deletes the blobs waiting on a snapshot once this write is on disk. The batch is the set
    /// as it is now, released only on this write's own receipt, so an earlier write finishing can
    /// never delete files that a later, not yet durable snapshot still lists. A failed write
    /// leaves the batch in the set for the next successful save.
    private func releaseBlobsOnceDurable(after receipt: HistorySnapshotWriteReceipt) {
        let batch = blobDeletionsAwaitingSnapshot
        guard !batch.isEmpty else { return }
        Task { [weak self] in
            guard case .success = await receipt.value() else { return }
            guard let self, !self.historyWritesDisabled else { return }
            self.releaseDeferredBlobDeletions(batch)
        }
    }

    /// Flush any pending debounced write synchronously. Called on app termination so the
    /// most recent history is durable before the process exits.
    func flushPendingWrites() {
        guard !historyWritesDisabled else { return }
        historyWriter.flush()
    }
}

extension ClipboardStore: SyncableStore {}
extension ClipboardStore: SyncEncryptionStatusReporting {}
extension ClipboardStore: SyncIssueReporting {}
extension ClipboardStore: PendingDeletionReporting {}
