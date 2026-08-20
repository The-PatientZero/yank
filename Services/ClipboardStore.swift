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

    /// Injected capture-relevant settings. Replaces reads of the
    /// `SettingsManager.shared` singleton on the capture critical path, so the store is
    /// testable in isolation. The composition root re-assigns this when the user changes
    /// the history limit or retention window.
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

    @ObservationIgnored var tombstones: [UUID: Date] = [:]
    @ObservationIgnored var historyWritesDisabled = false
    /// Reconcile may discover blobs that are no longer referenced before the replacement
    /// snapshot is durable. Keep those files until a successful flush, including across a
    /// failed sync retry, so the last durable snapshot never points at deleted content.
    @ObservationIgnored var pendingReconciledBlobDeletions: Set<ClipboardBlobReference> = []

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

    /// Owns the on-disk blob layout (texts / images / rich), its private-file attributes,
    /// and all blob reads/writes/deletes. The store delegates every filesystem concern here.
    @ObservationIgnored let blobStore: ClipBlobStore

    /// When capture-path age retention last ran. Age-based expiry is a coarse, time-driven
    /// sweep, so running it on every single capture is wasted work; we gate it to at most
    /// once per `expirySweepInterval` on the capture path. Explicit prune
    /// triggers (settings change, retention notification, launch) bypass the gate.
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

    init(settings: CaptureSettings, storageDirectory: URL? = nil) {
        self.captureSettings = settings
        self.blobStore = ClipBlobStore(storageDirectoryOverride: storageDirectory)
        if !blobStore.ensureDirectoriesExist() {
            storageUnavailable = true
        }
        loadSnapshot()
        pruneExpired()
        sweepOrphanedBlobsAtLaunch()
        hasLoaded = true
    }

    /// Apply age retention, the local history cap, and tombstone pruning. Explicit calls
    /// (launch, `captureSettings` change) bypass the capture-path time gate.
    func pruneExpired() {
        if applyRetentionAndLimit(now: Date()) { persist() }
    }

    /// One-shot sweep for blob files a reconcile's deferred delete never reached — a crash
    /// between the durable history flush and the actual file delete leaves the file behind
    /// with nothing left to re-derive it from. Runs synchronously inside `init`, before the
    /// watcher or sync exist to write a blob, so a capture in flight can never be mistaken
    /// for an orphan.
    private func sweepOrphanedBlobsAtLaunch() {
        guard let present = blobStore.allBlobReferences() else { return }
        let referenced = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) })
        let orphaned = present.subtracting(referenced)
        guard !orphaned.isEmpty else { return }
        blobStore.deleteBlobReferences(Array(orphaned))
        Log.store.info("Removed \(orphaned.count) orphaned blob file(s) at launch.")
    }

    // MARK: - Public API

    func add(
        _ item: ClipboardItem,
        richArchive: PasteboardArchive? = nil,
        observedAt: Date? = nil
    ) {
        var stamped = stampOrigin(on: item)
        guard !refreshDuplicateIfPresent(stamped, observedAt: observedAt) else { return }

        // Persist the full pasteboard archive only now that we know the item is being
        // inserted (not deduped) — so a rejected copy never orphans a rich file.
        if let archive = richArchive, let filename = saveRichArchive(archive) {
            stamped.richFilename = filename
        }
        insert(stamped, observedAt: observedAt)
    }

    /// Capture-specific insertion boundary. Duplicate resolution stays on the main actor and
    /// happens before any filesystem work; bounded primary/rich encoding and writes then run on
    /// a utility executor. Cancellation removes every newly written file before returning, and
    /// the caller's serial capture queue keeps the final in-memory mutations FIFO.
    func addCaptured(
        _ item: ClipboardItem,
        primaryBlob: ClipboardCapturePrimaryBlob?,
        richArchive: PasteboardArchive?,
        observedAt: Date? = nil
    ) async {
        var stamped = stampOrigin(on: item)
        if primaryBlob == nil, refreshDuplicateIfPresent(stamped, observedAt: observedAt) {
            return
        }

        if primaryBlob != nil || richArchive != nil {
            guard let persisted = await blobStore.persistCaptureBlobs(
                primary: primaryBlob,
                richArchive: richArchive
            ) else {
                return
            }
            guard !Task.isCancelled else {
                await blobStore.discardCaptureBlobs(persisted)
                return
            }
            stamped = applying(persisted, to: stamped)
        }

        insert(stamped, observedAt: observedAt)
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
        guard let existing = items
            .filter({ TextCaptureIdentity.matches($0, item) })
            .max(by: { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }) else {
            return false
        }
        _ = ClipboardMutations.refreshDuplicateCapture(
            existingID: existing.id,
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
            deviceOrigin: item.deviceOrigin
        )
    }

    private func insert(_ item: ClipboardItem, observedAt: Date?) {
        tombstones.removeValue(forKey: item.id)
        items.insert(item, at: 0)

        _ = applyHistoryLimit()

        // Age-based expiry is a day-granularity
        // sweep, so it need not run on every copy.
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

    private func loadSnapshot() {
        switch HistorySnapshotLoader.load(historyURL: historyFileURL, tombstonesURL: tombstonesFileURL) {
        case .success(let snapshot):
            items = snapshot.items
            tombstones = snapshot.tombstones
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
        blobStore.deleteBlobReferences(result.blobReferencesToDelete)
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
        blobStore.deleteBlobReferences(result.blobReferencesToDelete)
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

    func persist(notify: Bool = true) {
        guard !historyWritesDisabled else {
            Log.store.error("Skipped history save because the on-disk snapshot failed to load.")
            return
        }
        historyWriter.scheduleSave(items: items, tombstones: tombstones)
        if notify {
            NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: self)
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
