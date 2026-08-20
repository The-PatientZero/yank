import Foundation
import Observation
import os

/// iOS store log — declared locally because the macOS `Log` enum (`Services/Log.swift`)
/// is not compiled into the iOS target / its extensions. Same subsystem as the rest of
/// the app so entries land together in the unified log.
let clipStoreLog = Logger(subsystem: "com.thepatientzero.yank", category: "store")

/// iOS-side clipboard store. Captures the current clipboard while the host app
/// is active and accepts explicit extension handoffs; background clipboard
/// monitoring is not available on iOS. Persists into the shared App Group so
/// the keyboard and share extensions read the same data.
@MainActor
@Observable
final class ClipStore: SyncableStore {
    private struct PendingForegroundTextCapture {
        let pasteboardGeneration: Int
        let item: ClipboardItem
        let deferredBlobDeletions: Set<ClipboardBlobReference>
    }

    private enum PersistenceError: LocalizedError {
        case appGroupUnavailable
        case writesDisabled
        case invalidShareCapture
        case blobWriteFailed

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "The shared App Group container is unavailable."
            case .writesDisabled:
                "History writes are disabled because the saved snapshot could not be loaded."
            case .invalidShareCapture:
                "A pending shared item is invalid."
            case .blobWriteFailed:
                "A shared clip payload could not be saved."
            }
        }
    }

    private(set) var items: [ClipboardItem] = [] {
        didSet {
            filterCache.invalidate()
            tagCache = nil
            contentRevision &+= 1
        }
    }

    /// Monotonic in-process signal for consumers that care about content edits, not just count.
    private(set) var contentRevision: UInt64 = 0

    private(set) var firstSyncState: FirstSyncState = .idle

    private(set) var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)

    /// True when the blobs container could not be created or its at-rest data-protection
    /// class could not be set — so synced image/text blobs may be missing or weaker than
    /// `completeUntilFirstUserAuthentication` at rest. Surfaced for the UI; never silently
    /// swallowed.
    private(set) var storageUnavailable = false

    @ObservationIgnored private var tombstones: [UUID: Date] = [:]
    /// Blobs removed by reconciliation stay available until the replacement history and
    /// tombstones have both flushed. The set survives a failed in-process retry so a later
    /// successful snapshot can finish the cleanup without risking data loss.
    @ObservationIgnored private var pendingReconciledBlobDeletions: Set<ClipboardBlobReference> = []

    private(set) var pendingDeletion: PendingDeletion? {
        didSet { filterCache.invalidate() }
    }

    /// Memoised filtered/sorted view of `items`; invalidated whenever `items` changes.
    /// Internal (not private) so the app-only `filteredItems` in `ClipStore+Mutations`
    /// can read/write it — `ClipQuery` lives in the app, not the lean extensions, which
    /// also compile this file.
    @ObservationIgnored var filterCache = ClipFilterCache()
    @ObservationIgnored var tagCache: [String]?

    @ObservationIgnored private var historyWritesDisabled = false
    @ObservationIgnored private let appGroupContext: AppGroupContext?
    @ObservationIgnored private var isDrainingShareInbox = false
    @ObservationIgnored private var pendingForegroundTextCapture: PendingForegroundTextCapture?
    @ObservationIgnored private var latestHistoryWriteReceipt: HistorySnapshotWriteReceipt?

    /// Shared snapshot → encode → write pipeline (same type the Mac store uses). The iOS
    /// store captures one item at a time (no bursts) and is also compiled into the lean
    /// keyboard/share extensions, so it writes immediately (debounce `.zero`) rather than
    /// risk losing a write when an extension is torn down.
    @ObservationIgnored private lazy var historyWriter: HistorySnapshotWriter? = {
        guard let appGroupContext else { return nil }
        return HistorySnapshotWriter(
            historyURL: appGroupContext.historyURL,
            tombstonesURL: appGroupContext.tombstonesURL,
            writeOptions: Self.historyWriteOptions,
            queueLabel: "com.thepatientzero.yank.ios.save"
        )
    }()

    nonisolated static let appGroup = AppGroupContext.identifier
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

    private var historyURL: URL? { appGroupContext?.historyURL }
    private var tombstonesURL: URL? { appGroupContext?.tombstonesURL }
    /// All blob filesystem work lives here; the store keeps history, persistence, and sync.
    private let blobStore: IOSClipBlobStore

    /// Settings the user set in-app (App-Group backed). `0` means unlimited / off.
    private var prefs: UserDefaults? { appGroupContext?.defaults }
    private var historyLimit: Int { prefs?.integer(forKey: SettingsKeys.historyLimit) ?? 0 }
    private var retentionDays: Int { prefs?.integer(forKey: SettingsKeys.retentionDays) ?? 0 }

    init(context: AppGroupContext? = AppGroupContext.live()) {
        self.appGroupContext = context
        self.blobStore = IOSClipBlobStore(directory: context?.blobsURL)
        guard let context else {
            storageUnavailable = true
            historyWritesDisabled = true
            clipStoreLog.error("App Group container is unavailable; iOS storage is disabled.")
            return
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: context.blobsURL, withIntermediateDirectories: true)
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
                ofItemAtPath: context.blobsURL.path
            )
        } catch {
            storageUnavailable = true
            clipStoreLog.error("Failed to set iOS blobs data-protection class: \(error.localizedDescription)")
        }
        protectExistingHistoryFiles()
        load()
        if !historyWritesDisabled {
            sweepOrphanBlobs()
            publishKeyboardProjection()
        }
    }

    /// Capture text from the foreground clipboard, share extension, or App Intent. Large text
    /// is file-backed and oversized text is truncated — the same size policy the Mac uses — so
    /// a huge clip can't bloat the in-memory history or the synced `textContent` field.
    func capture(text: String, sourceApp: String? = nil) async {
        _ = await captureText(
            text,
            sourceApp: sourceApp,
            pasteboardGeneration: nil,
            hasRichContent: false
        )
    }

    /// Capture a foreground pasteboard generation and return only after its canonical
    /// history snapshot is durable. A failed receipt remains retryable under the same
    /// generation without creating another file-backed item or blob.
    @discardableResult
    func captureForegroundText(
        _ text: String,
        pasteboardGeneration: Int,
        hasRichContent: Bool,
        sourceApp: String? = nil
    ) async -> IOSForegroundCaptureOutcome {
        await captureText(
            text,
            sourceApp: sourceApp,
            pasteboardGeneration: pasteboardGeneration,
            hasRichContent: hasRichContent
        )
    }

    private func captureText(
        _ text: String,
        sourceApp: String?,
        pasteboardGeneration: Int?,
        hasRichContent: Bool
    ) async -> IOSForegroundCaptureOutcome {
        guard !historyWritesDisabled else { return .retryableFailure }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .terminalPolicyRejection
        }

        if let pasteboardGeneration,
           let pending = pendingForegroundTextCapture,
           pending.pasteboardGeneration == pasteboardGeneration,
           let current = items.first(where: { $0.id == pending.item.id }),
           isSameForegroundCaptureVersion(current, pending.item) {
            let receipt = persist(notify: false)
            return await finishForegroundCapture(
                itemID: pending.item.id,
                pasteboardGeneration: pasteboardGeneration,
                receipt: receipt
            )
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
            guard let filename = await saveTextBlob(fullText) else {
                return .retryableFailure
            }
            item = ClipboardItem.largeText(
                preview: preview, filename: filename, sourceApp: sourceApp,
                originalSizeBytes: originalSizeBytes, searchIndex: searchIndex
            )
        case .truncated(let preview, let originalSizeBytes):
            item = ClipboardItem.truncatedText(
                preview: preview, originalSizeBytes: originalSizeBytes, sourceApp: sourceApp
            )
        }
        item.hasRichContent = hasRichContent
        item.deviceOrigin = DeviceIdentity.current
        if case .inline = plan.storage,
           let refreshedID = refreshDuplicateCapture(with: item) {
            prepareForegroundCapture(
                itemID: refreshedID,
                pasteboardGeneration: pasteboardGeneration,
                deferredBlobDeletions: []
            )
            let receipt = persist(notify: pasteboardGeneration == nil)
            return await finishForegroundCapture(
                itemID: refreshedID,
                pasteboardGeneration: pasteboardGeneration,
                receipt: receipt
            )
        }
        items.insert(item, at: 0)
        let deferredBlobDeletions = applyHistoryLimit(
            deferBlobDeletion: pasteboardGeneration != nil
        )
        prepareForegroundCapture(
            itemID: item.id,
            pasteboardGeneration: pasteboardGeneration,
            deferredBlobDeletions: deferredBlobDeletions
        )
        let receipt = persist(notify: pasteboardGeneration == nil)
        return await finishForegroundCapture(
            itemID: item.id,
            pasteboardGeneration: pasteboardGeneration,
            receipt: receipt
        )
    }

    private func prepareForegroundCapture(
        itemID: UUID,
        pasteboardGeneration: Int?,
        deferredBlobDeletions: [ClipboardBlobReference]
    ) {
        guard let pasteboardGeneration else { return }
        let carriedDeletions = pendingForegroundTextCapture?.deferredBlobDeletions ?? []
        let item = items.first { $0.id == itemID }
        guard let item else { return }
        pendingForegroundTextCapture = PendingForegroundTextCapture(
            pasteboardGeneration: pasteboardGeneration,
            item: item,
            deferredBlobDeletions: carriedDeletions.union(deferredBlobDeletions)
        )
    }

    /// Compare only fields owned by capture. User and derived annotations may legitimately
    /// change while a failed checkpoint is pending, but a remote replacement of the record's
    /// payload must not be mistaken for the original pasteboard capture.
    private func isSameForegroundCaptureVersion(
        _ current: ClipboardItem,
        _ pending: ClipboardItem
    ) -> Bool {
        current.id == pending.id
            && current.type == pending.type
            && current.timestamp == pending.timestamp
            && current.sourceApp == pending.sourceApp
            && current.textContent == pending.textContent
            && current.textFilename == pending.textFilename
            && current.imageFilename == pending.imageFilename
            && current.richFilename == pending.richFilename
            && current.hasRichContent == pending.hasRichContent
            && current.isTruncated == pending.isTruncated
            && current.originalSizeBytes == pending.originalSizeBytes
            && current.searchIndex == pending.searchIndex
            && current.modifiedAt == pending.modifiedAt
            && current.deletedAt == pending.deletedAt
            && current.deviceOrigin == pending.deviceOrigin
    }

    private func finishForegroundCapture(
        itemID: UUID,
        pasteboardGeneration: Int?,
        receipt: HistorySnapshotWriteReceipt?
    ) async -> IOSForegroundCaptureOutcome {
        guard let pasteboardGeneration else { return .durable }
        guard let receipt else { return .retryableFailure }
        switch await receipt.value() {
        case .success:
            if pendingForegroundTextCapture?.pasteboardGeneration == pasteboardGeneration,
               pendingForegroundTextCapture?.item.id == itemID {
                let referencedBlobs = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) })
                let orphanedBlobs = pendingForegroundTextCapture?
                    .deferredBlobDeletions
                    .subtracting(referencedBlobs) ?? []
                deleteBlobReferences(Array(orphanedBlobs))
                pendingForegroundTextCapture = nil
            }
            NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: self)
            return .durable
        case .failure(let error):
            clipStoreLog.error(
                "Failed to durably save foreground pasteboard capture: \(error.localizedDescription)"
            )
            return .retryableFailure
        }
    }

    private func saveTextBlob(_ text: String, filename: String? = nil) async -> String? {
        await blobStore.saveText(text, filename: filename)
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

    private func saveImageBlob(_ data: Data, filename: String? = nil) async -> String? {
        await blobStore.saveImage(data, filename: filename)
    }

    /// Import file-per-capture extension handoffs into canonical history. Each entry is
    /// removed only after the canonical snapshot is durably committed; stable entry IDs
    /// make a retry after interruption idempotent.
    @discardableResult
    func drainShareInbox() async -> Set<String> {
        var successfulSources: Set<String> = []
        guard !storageUnavailable,
              !historyWritesDisabled,
              !isDrainingShareInbox,
              let inbox = appGroupContext?.shareInbox else { return successfulSources }
        isDrainingShareInbox = true
        defer { isDrainingShareInbox = false }
        do {
            let entries = try await Task.detached(priority: .utility) {
                try inbox.recoverablePendingEntries()
            }.value
            for entry in entries {
                do {
                    var didImport = false
                    if !items.contains(where: { $0.id == entry.id }) {
                        try await importShareCapture(entry, from: inbox)
                        didImport = true
                    }
                    // Always schedule the current canonical state before removing the
                    // handoff. A prior failed writer operation has already been consumed;
                    // seeing the ID in memory alone is not proof that it reached disk.
                    persist(notify: didImport)
                    try flushPendingWrites()
                    try await Task.detached(priority: .utility) {
                        try inbox.remove(entry)
                    }.value
                    if let source = entry.sourceApp {
                        successfulSources.insert(source)
                    }
                } catch {
                    guard isUnrecoverableSharePayloadError(error) else { throw error }
                    try await Task.detached(priority: .utility) {
                        try inbox.remove(entry)
                    }.value
                    clipStoreLog.error("Discarded an invalid shared image payload.")
                }
            }
        } catch {
            clipStoreLog.error("Failed to import shared capture: \(error.localizedDescription)")
        }
        return successfulSources
    }

    private func isUnrecoverableSharePayloadError(_ error: any Error) -> Bool {
        guard let inboxError = error as? ShareCaptureInbox.Error else { return false }
        switch inboxError {
        case .invalidEntry, .missingPayload, .payloadTooLarge:
            return true
        case .quotaExceeded, .textTooLarge, .unsupportedVersion:
            return false
        }
    }

    private func importShareCapture(
        _ entry: ShareCaptureInbox.Entry,
        from inbox: ShareCaptureInbox
    ) async throws {
        switch entry.kind {
        case .text:
            try await importTextShareCapture(entry)
        case .image:
            try await importImageShareCapture(entry, from: inbox)
        }
    }

    private func importTextShareCapture(_ entry: ShareCaptureInbox.Entry) async throws {
        guard let text = entry.text else { throw PersistenceError.invalidShareCapture }
        let plan = TextCapturePlan.make(
            for: text,
            inlineLimit: Self.inlineTextLimit,
            previewLength: Self.previewLength,
            maxStoredBytes: SyncBlobKind.text.maximumBytes
        )
        var item = try await importedTextItem(for: entry, storage: plan.storage)
        item.deviceOrigin = DeviceIdentity.current
        if refreshDuplicateCapture(with: item) != nil { return }
        insertImported(item)
    }

    private func importedTextItem(
        for entry: ShareCaptureInbox.Entry,
        storage: TextCapturePlan.Storage
    ) async throws -> ClipboardItem {
        switch storage {
        case .inline(let content):
            return ClipboardItem(
                id: entry.id, type: .text, timestamp: entry.createdAt,
                sourceApp: entry.sourceApp, textContent: content, modifiedAt: entry.createdAt
            )
        case .fileBacked(let preview, let fullText, let originalSizeBytes, let searchIndex):
            let filename = entry.id.uuidString + "." + SyncBlobKind.text.allowedExtension
            guard await saveTextBlob(fullText, filename: filename) != nil else {
                throw PersistenceError.blobWriteFailed
            }
            return ClipboardItem(
                id: entry.id, type: .text, timestamp: entry.createdAt,
                sourceApp: entry.sourceApp, textContent: preview, textFilename: filename,
                originalSizeBytes: originalSizeBytes, searchIndex: searchIndex,
                modifiedAt: entry.createdAt
            )
        case .truncated(let preview, let originalSizeBytes):
            return ClipboardItem(
                id: entry.id, type: .text, timestamp: entry.createdAt,
                sourceApp: entry.sourceApp, textContent: preview, isTruncated: true,
                originalSizeBytes: originalSizeBytes, modifiedAt: entry.createdAt
            )
        }
    }

    private func importImageShareCapture(
        _ entry: ShareCaptureInbox.Entry,
        from inbox: ShareCaptureInbox
    ) async throws {
        let data = try await Task.detached(priority: .userInitiated) {
            try inbox.imagePayload(for: entry)
        }.value
        let filename = entry.id.uuidString + "." + SyncBlobKind.image.allowedExtension
        guard await saveImageBlob(data, filename: filename) != nil else {
            throw PersistenceError.blobWriteFailed
        }
        insertImported(
            ClipboardItem(
                id: entry.id, type: .image, timestamp: entry.createdAt,
                sourceApp: entry.sourceApp, imageFilename: filename,
                modifiedAt: entry.createdAt
            )
        )
    }

    private func insertImported(_ importedItem: ClipboardItem) {
        var item = importedItem
        item.deviceOrigin = DeviceIdentity.current
        items.insert(item, at: 0)
        applyHistoryLimit()
    }

    /// Resolve a new local inline-text capture against existing eligible records. Sync itself
    /// remains UUID-based; this is invoked only from explicit local capture/ingestion paths.
    private func refreshDuplicateCapture(with incoming: ClipboardItem) -> UUID? {
        let existing = items
            .filter { TextCaptureIdentity.matches($0, incoming) }
            .max { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let existing,
              ClipboardMutations.refreshDuplicateCapture(
            existingID: existing.id,
            with: incoming,
            in: &items
              ) else { return nil }
        return existing.id
    }

    /// Mark an item most-recently-used (e.g. after copying it to the pasteboard).
    func touch(_ item: ClipboardItem) {
        moveToTop(item.id)
    }

    private func moveToTop(_ id: UUID) {
        guard ClipboardMutations.moveToTop(id, in: &items) else { return }
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
                "Reconcile cap dropped \(result.cappedVisibleCount) clip(s); local limit is \(self.historyLimit)."
            )
        }
        if result.expiredVisibleCount > 0 {
            clipStoreLog.info("Reconcile retention expired \(result.expiredVisibleCount) synced clip(s).")
        }
        pendingReconciledBlobDeletions.formUnion(result.blobReferencesToDelete)
        items = result.visibleItems
        tombstones = result.tombstones
        firstSyncState = .settled
        markSyncSucceeded(at: Date())
        persist(notify: result.expiredVisibleCount > 0)
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) throws {
        guard !historyWritesDisabled else { throw PersistenceError.writesDisabled }
        applyReconciled(canonical)
        try flushPendingWrites()
        let referencedBlobs = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) })
        let orphanedBlobs = pendingReconciledBlobDeletions.subtracting(referencedBlobs)
        deleteBlobReferences(Array(orphanedBlobs))
        pendingReconciledBlobDeletions.removeAll()
    }

    func blobURL(for item: ClipboardItem) -> URL? {
        blobStore.url(for: item)
    }

    func pasteboardOriginMarkerForWrite(
        bundleIdentifier: String?
    ) -> IOSPasteboardOriginMarker? {
        appGroupContext?.pasteboardOriginMarkerForWrite(
            bundleIdentifier: bundleIdentifier
        )
    }

    func pasteboardHasMatchingOriginTag(
        bundleIdentifier: String?,
        pasteboardTypes: [String],
        readData: (String) -> Data?
    ) -> Bool {
        appGroupContext?
            .existingPasteboardOriginMarker(bundleIdentifier: bundleIdentifier)?
            .matches(pasteboardTypes: pasteboardTypes, readData: readData) ?? false
    }

    func blobURL(for reference: SyncBlobReference) -> URL? {
        blobStore.url(for: reference)
    }

    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws {
        guard blobStore.isAvailable else { throw PersistenceError.appGroupUnavailable }
        try await blobStore.write(data, reference: reference)
    }

    func deleteBlob(_ reference: SyncBlobReference) {
        blobStore.delete(reference)
    }

    private func deleteBlobReferences(_ references: [ClipboardBlobReference]) {
        blobStore.delete(references)
    }

    @discardableResult
    private func applyHistoryLimit(
        deferBlobDeletion: Bool = false
    ) -> [ClipboardBlobReference] {
        guard let result = historyLimitCapResult() else { return [] }
        if !deferBlobDeletion {
            deleteBlobReferences(result.blobReferencesToDelete)
        }
        items = result.items
        return result.blobReferencesToDelete
    }

    private func historyLimitCapResult() -> ClipboardRetention.CapResult? {
        guard historyLimit > 0, items.count > historyLimit else { return nil }
        let result = ClipboardRetention.cap(items, limit: historyLimit)
        return result.items == items ? nil : result
    }

    private func protectExistingHistoryFiles() {
        let fileManager = FileManager.default
        for url in [historyURL, tombstonesURL].compactMap({ $0 })
            where fileManager.fileExists(atPath: url.path) {
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
        guard let historyURL, let tombstonesURL else {
            storageUnavailable = true
            historyWritesDisabled = true
            return
        }
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

    /// Once per launch, after the snapshot loads and before sync or capture can add anything.
    /// Only called on a successful load — an empty `items` from a failed one would make every
    /// existing blob look orphaned.
    private func sweepOrphanBlobs() {
        let referenced = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) }.map(\.filename))
        let removedCount = blobStore.sweepOrphans(referenced: referenced)
        if removedCount > 0 {
            clipStoreLog.info("Removed \(removedCount) orphaned iOS blob file(s) at launch.")
        }
    }

    /// Snapshot on the calling (main) actor, then build and encode both the canonical snapshot
    /// and bounded keyboard projection on the writer's utility queue. The local-change
    /// notification (which schedules a sync push) is thread-agnostic on the receiver.
    @discardableResult
    private func persist(notify: Bool = true) -> HistorySnapshotWriteReceipt? {
        guard !historyWritesDisabled, let historyWriter else {
            clipStoreLog.error("Skipped iOS history save because the on-disk snapshot failed to load.")
            return nil
        }
        let projectionURL = appGroupContext?.keyboardProjectionURL
        let receipt = historyWriter.scheduleSave(
            items: items,
            tombstones: tombstones,
            keyboardProjectionURL: projectionURL,
            onKeyboardProjectionError: { error in
                clipStoreLog.error("Failed to publish keyboard history: \(error.localizedDescription)")
            }
        )
        latestHistoryWriteReceipt = receipt
        if notify {
            NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: self)
        }
        return receipt
    }

    /// Synchronously commit the latest scheduled snapshot before an extension or App Intent
    /// returns control to the system and risks suspension.
    func flushPendingWrites() throws {
        guard !historyWritesDisabled else { throw PersistenceError.writesDisabled }
        guard let historyWriter else { throw PersistenceError.appGroupUnavailable }
        try historyWriter.flush().get()
    }

    /// Await the newest iOS snapshot without blocking the main actor. The iOS writer
    /// dispatches every save immediately (`debounce == .zero`), so its exact receipt is
    /// also the completion boundary for the paired history/tombstone transaction.
    func flushPendingWritesBeforeSuspension() async throws {
        guard !historyWritesDisabled else { throw PersistenceError.writesDisabled }
        guard historyWriter != nil else { throw PersistenceError.appGroupUnavailable }

        while let receipt = latestHistoryWriteReceipt {
            try Task.checkCancellation()
            let result = await receipt.value()
            try Task.checkCancellation()
            guard latestHistoryWriteReceipt === receipt else { continue }
            try result.get()
            return
        }
    }

    private func publishKeyboardProjection() {
        guard let appGroupContext, let historyWriter else { return }
        historyWriter.scheduleKeyboardProjection(
            items: items,
            to: appGroupContext.keyboardProjectionURL,
            onError: { [weak self] error in
                clipStoreLog.error("Failed to publish keyboard history: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.storageUnavailable = true
                }
            }
        )
    }
}
