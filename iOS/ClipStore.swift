import Foundation
import Observation
import os

/// iOS store log — declared locally because the macOS `Log` enum (`Services/Log.swift`)
/// is not compiled into the iOS target / its extensions. Same subsystem as the rest of
/// the app so entries land together in the unified log.
let clipStoreLog = Logger(subsystem: "com.thepatientzero.yank", category: "store")

/// iOS-side clipboard store. The synced history from CloudKit is the source of
/// truth — capture on iOS is manual. Persists into the shared App
/// Group so the keyboard and share extensions read the same data.
@MainActor
@Observable
final class ClipStore: SyncableStore {
    private(set) var items: [ClipboardItem] = [] {
        didSet {
            filterCache = nil
            tagCache = nil
        }
    }

    private(set) var firstSyncState: FirstSyncState = .idle

    private(set) var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)

    /// True when the blobs container could not be created or its at-rest data-protection
    /// class could not be set — so synced image/text blobs may be missing or weaker than
    /// `completeUntilFirstUserAuthentication` at rest. Surfaced for the UI; never silently
    /// swallowed.
    private(set) var storageUnavailable = false

    @ObservationIgnored private var tombstones: [UUID: Date] = [:]

    private(set) var pendingDeletion: PendingDeletion? {
        didSet { filterCache = nil }
    }

    /// Memoised filtered/sorted view of `items`; invalidated whenever `items` changes.
    /// Internal (not private) so the app-only `filteredItems` in `ClipStore+Mutations`
    /// can read/write it — `ClipQuery` lives in the app, not the lean extensions, which
    /// also compile this file.
    @ObservationIgnored var filterCache: (query: String, tag: String?, result: [ClipboardItem])?
    @ObservationIgnored var tagCache: [String]?

    @ObservationIgnored private var historyWritesDisabled = false

    /// Shared snapshot → encode → write pipeline (same type the Mac store uses). The iOS
    /// store captures one item at a time (no bursts) and is also compiled into the lean
    /// keyboard/share extensions, so it writes immediately (debounce `.zero`) rather than
    /// risk losing a write when an extension is torn down.
    @ObservationIgnored private lazy var historyWriter = HistorySnapshotWriter(
        historyURL: historyURL,
        tombstonesURL: tombstonesURL,
        writeOptions: Self.historyWriteOptions,
        queueLabel: "com.thepatientzero.yank.ios.save"
    )

    nonisolated static let appGroup = "group.com.thepatientzero.yank"
    nonisolated private static let historyWriteOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication
    ]

    // Same text-size policy the Mac watcher uses: inline ≤ 50 KB, file-back up to the blob
    // ceiling, truncate above it. Keeps a single huge clip from bloating the in-memory
    // history (critical for the memory-constrained keyboard extension) and the synced
    // `textContent` field.
    nonisolated private static let inlineTextLimit = 50_000
    nonisolated private static let previewLength = 500

    private var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var historyURL: URL { containerURL.appendingPathComponent("history.json") }
    private var tombstonesURL: URL { containerURL.appendingPathComponent("tombstones.json") }
    private var blobsURL: URL { containerURL.appendingPathComponent("blobs", isDirectory: true) }

    /// Settings the user set in-app (App-Group backed). `0` means unlimited / off.
    private var prefs: UserDefaults { UserDefaults(suiteName: Self.appGroup) ?? .standard }
    private var historyLimit: Int { prefs.integer(forKey: SettingsKeys.historyLimit) }
    private var retentionDays: Int { prefs.integer(forKey: SettingsKeys.retentionDays) }

    init() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        } catch {
            storageUnavailable = true
            clipStoreLog.error("Failed to create iOS blobs directory: \(error.localizedDescription)")
        }
        // Make the at-rest data-protection class explicit — it's the iOS default for App-Group
        // containers, but stating it keeps blobs encrypted-at-rest after first unlock while
        // still readable in the background for sync and the extensions. A failure here
        // silently weakens at-rest encryption, so surface it rather than dropping it.
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: blobsURL.path
            )
        } catch {
            storageUnavailable = true
            clipStoreLog.error("Failed to set iOS blobs data-protection class: \(error.localizedDescription)")
        }
        protectExistingHistoryFiles()
        load()
    }

    /// Manually capture text (share extension, App Intent, in-app paste). Large text is
    /// file-backed and oversized text is truncated — the same size policy the Mac uses — so a
    /// huge clip can't bloat the in-memory history or the synced `textContent` field.
    func capture(text: String, sourceApp: String? = nil) async {
        guard !historyWritesDisabled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let existing = items.first(where: { $0.textContent == text }) {
            moveToTop(existing.id)
            return
        }

        let plan = TextCapturePlan.make(
            for: text,
            inlineLimit: Self.inlineTextLimit,
            previewLength: Self.previewLength,
            maxStoredBytes: SyncBlobKind.text.maximumBytes
        )

        var item: ClipboardItem
        switch plan.storage {
        case .inline(let content):
            item = ClipboardItem.text(content, sourceApp: sourceApp)
        case .fileBacked(let preview, let fullText, let originalSizeBytes, let searchIndex):
            guard let filename = await saveTextBlob(fullText) else { return }
            item = ClipboardItem.largeText(
                preview: preview, filename: filename, sourceApp: sourceApp,
                originalSizeBytes: originalSizeBytes, searchIndex: searchIndex
            )
        case .truncated(let preview, let originalSizeBytes):
            item = ClipboardItem.truncatedText(
                preview: preview, originalSizeBytes: originalSizeBytes, sourceApp: sourceApp
            )
        }
        item.deviceOrigin = DeviceIdentity.current
        items.insert(item, at: 0)
        applyHistoryLimit()
        persist()
    }

    private func saveTextBlob(_ text: String) async -> String? {
        let filename = UUID().uuidString + "." + SyncBlobKind.text.allowedExtension
        guard let url = SyncBlobPolicy.containedURL(directory: blobsURL, filename: filename, kind: .text) else {
            return nil
        }
        do {
            try await SyncBlobStorage.write(Data(text.utf8), to: url, maxBytes: SyncBlobKind.text.maximumBytes)
            return filename
        } catch {
            clipStoreLog.error("Failed to save iOS text blob: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func captureImage(pngData: Data, sourceApp: String? = nil) async -> Bool {
        guard !historyWritesDisabled else { return false }
        guard let filename = await saveImageBlob(pngData) else { return false }
        var item = ClipboardItem.image(filename: filename, sourceApp: sourceApp)
        item.deviceOrigin = DeviceIdentity.current
        items.insert(item, at: 0)
        applyHistoryLimit()
        persist()
        return true
    }

    private func saveImageBlob(_ data: Data) async -> String? {
        let filename = UUID().uuidString + "." + SyncBlobKind.image.allowedExtension
        guard let url = SyncBlobPolicy.containedURL(directory: blobsURL, filename: filename, kind: .image) else {
            return nil
        }
        do {
            try await SyncBlobStorage.write(data, to: url)
            return filename
        } catch {
            clipStoreLog.error("Failed to save iOS image blob: \(error.localizedDescription)")
            return nil
        }
    }

    /// Mark an item most-recently-used (e.g. after copying it to the pasteboard).
    func touch(_ item: ClipboardItem) {
        moveToTop(item.id)
    }

    private func moveToTop(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var moved = items.remove(at: index)
        moved.modifiedAt = Date()
        items.insert(moved, at: 0)
        persist()
    }

    func delete(_ item: ClipboardItem) {
        softDelete([item])
    }

    func delete(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        softDelete(items)
    }

    private func softDelete(_ toDelete: [ClipboardItem]) {
        commitPendingDelete()
        pendingDeletion = PendingDeletion(items: toDelete, enqueuedAt: Date())
    }

    func undoPendingDelete() {
        pendingDeletion = nil
    }

    func commitPendingDelete() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        removeItems(ids: Set(pending.items.map(\.id)))
    }

    /// Shared removal glue: tombstone the ids, drop orphaned blobs, persist.
    /// Identical pure decisions as the macOS store via `ClipboardMutations.removeItems`.
    private func removeItems(ids: Set<UUID>) {
        let result = ClipboardMutations.removeItems(ids: ids, from: items)
        deleteBlobReferences(result.blobReferencesToDelete)
        recordTombstones(result.tombstones)
        items = result.items
        persist()
    }

    private func recordTombstones(_ newTombstones: [UUID: Date]) {
        for (id, date) in newTombstones {
            tombstones[id] = date
        }
    }

    /// Apply an in-place edit to the clip list and persist (which schedules a sync
    /// push). The one mutation entry point, so `items`' setter stays encapsulated and
    /// the feature edits (pin/bookmark/tag/OCR) can live in an app-only extension.
    func mutate(_ block: (inout [ClipboardItem]) -> Void) {
        block(&items)
        persist()
    }

    /// Remove every clip, leaving tombstones so the clearance propagates via sync.
    func clear() {
        pendingDeletion = nil
        removeItems(ids: Set(items.map(\.id)))
    }

    /// Apply the configured age-retention then history limit (call from the app on
    /// launch and after a settings change). Expired unprotected clips are tombstoned so
    /// the deletion propagates; the limit only trims local storage (capped clips stay in
    /// the cloud). No-ops when both are off.
    func enforceRetentionAndLimit() {
        let result = ClipboardRetention.enforce(
            items: items,
            tombstones: tombstones,
            historyLimit: historyLimit,
            retentionDays: retentionDays,
            now: Date()
        )
        guard result.didChange else { return }
        deleteBlobReferences(result.blobReferencesToDelete)
        items = result.items
        tombstones = result.tombstones
        persist()
    }

    // MARK: - SyncableStore

    func markSyncStarted() {
        syncStatus = .syncing
        if firstSyncState != .settled {
            firstSyncState = .syncing
        }
    }

    func markSyncSucceeded(at date: Date) {
        syncStatus = .healthy(lastSynced: date)
    }

    func markSyncFailed(_ message: String) {
        syncStatus = .failed(message: message)
        if firstSyncState != .settled {
            firstSyncState = .failed(message: message)
        }
    }

    func markSyncUnavailable(reason: SyncStatus.Reason) {
        syncStatus = .localOnly(reason: reason)
    }

    func itemsForSync() -> [ClipboardItem] {
        items + SyncReconcile.tombstoneItems(tombstones)
    }

    func applyReconciled(_ canonical: [ClipboardItem]) {
        let result = SyncReconcile.apply(
            canonical: canonical,
            replacing: items,
            historyLimit: historyLimit,
            retentionDays: retentionDays,
            now: Date()
        )
        if result.cappedVisibleCount > 0 {
            clipStoreLog.info(
                "Reconcile cap dropped \(result.cappedVisibleCount) synced clip(s) — local history limit is \(self.historyLimit)."
            )
        }
        if result.expiredVisibleCount > 0 {
            clipStoreLog.info("Reconcile retention expired \(result.expiredVisibleCount) synced clip(s).")
        }
        deleteBlobReferences(result.blobReferencesToDelete)
        items = result.visibleItems
        tombstones = result.tombstones
        firstSyncState = .settled
        markSyncSucceeded(at: Date())
        persist(notify: result.expiredVisibleCount > 0)
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) {
        applyReconciled(canonical)
        flushPendingWrites()
    }

    func blobURL(for item: ClipboardItem) -> URL? {
        if let filename = item.imageFilename {
            return SyncBlobPolicy.containedURL(directory: blobsURL, filename: filename, kind: .image)
        }
        if let filename = item.textFilename {
            return SyncBlobPolicy.containedURL(directory: blobsURL, filename: filename, kind: .text)
        }
        return nil
    }

    func blobURL(for reference: SyncBlobReference) -> URL? {
        reference.containedURL(in: blobsURL)
    }

    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws {
        guard let url = reference.containedURL(in: blobsURL) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        try await SyncBlobStorage.write(data, to: url, maxBytes: reference.maximumBytes)
    }

    func deleteBlob(_ reference: SyncBlobReference) {
        guard let url = reference.containedURL(in: blobsURL) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func deleteBlobReferences(_ references: [ClipboardBlobReference]) {
        for reference in references {
            switch reference.kind {
            case .image, .text:
                let kind: SyncBlobKind = reference.kind == .image ? .image : .text
                guard let url = SyncBlobPolicy.containedURL(
                    directory: blobsURL,
                    filename: reference.filename,
                    kind: kind
                ) else { continue }
                try? FileManager.default.removeItem(at: url)
            case .rich:
                break
            }
        }
    }

    @discardableResult
    private func applyHistoryLimit() -> Bool {
        guard let result = historyLimitCapResult() else { return false }
        deleteBlobReferences(result.blobReferencesToDelete)
        items = result.items
        return true
    }

    private func historyLimitCapResult() -> ClipboardRetention.CapResult? {
        guard historyLimit > 0, items.count > historyLimit else { return nil }
        let result = ClipboardRetention.cap(items, limit: historyLimit)
        return result.items == items ? nil : result
    }

    private func protectExistingHistoryFiles() {
        let fileManager = FileManager.default
        for url in [historyURL, tombstonesURL] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                storageUnavailable = true
                clipStoreLog.error("Failed to set iOS history data-protection class: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        switch HistorySnapshotLoader.load(historyURL: historyURL, tombstonesURL: tombstonesURL) {
        case .success(let snapshot):
            items = snapshot.items
            tombstones = snapshot.tombstones
        case .failure(let error):
            storageUnavailable = true
            historyWritesDisabled = true
            clipStoreLog.error("Failed to load iOS history snapshot: \(error.localizedDescription)")
        }
    }

    /// Snapshot on the calling (main) actor, then encode + write on a background queue —
    /// so a full-history rewrite never hitches the UI on a pin/tag/copy. The local-change
    /// notification (which schedules a sync push) is thread-agnostic on the receiver.
    private func persist(notify: Bool = true) {
        guard !historyWritesDisabled else {
            clipStoreLog.error("Skipped iOS history save because the on-disk snapshot failed to load.")
            return
        }
        historyWriter.scheduleSave(items: items, tombstones: tombstones)
        if notify {
            NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: self)
        }
    }

    /// Synchronously commit the latest scheduled snapshot before an extension or App Intent
    /// returns control to the system and risks suspension.
    func flushPendingWrites() {
        guard !historyWritesDisabled else { return }
        historyWriter.flush()
    }
}
