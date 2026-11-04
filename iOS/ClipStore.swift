import Foundation
import Observation
import os

/// iOS store log — declared locally because the macOS `Log` enum (`Services/Log.swift`)
/// is not compiled into the iOS target / its extensions. Same subsystem as the rest of
/// the app so entries land together in the unified log.
let clipStoreLog = Logger(subsystem: "com.thepatientzero.yank", category: "store")

/// iOS clipboard store. Captures the clipboard while the host app is foreground or via explicit
/// extension handoff — no background clipboard monitoring on iOS. Persists to the shared App
/// Group so the keyboard and share extensions read the same data.
@MainActor
@Observable
final class ClipStore: SyncableStore, SyncEncryptionStatusReporting, SyncIssueReporting, PendingDeletionReporting {
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

    /// History elements this build cannot read (for example written by another version). They
    /// are written back unchanged on every save and their files are never deleted. Observed so
    /// the history screen can tell the user.
    private(set) var heldElements: [HeldHistoryElement] = [] {
        didSet { blobStore.protectedFilenames = Set(heldElements.flatMap(\.filenames)) }
    }

    var heldClipCount: Int { heldElements.count }

    /// Monotonic in-process signal for consumers that care about content edits, not just count.
    private(set) var contentRevision: UInt64 = 0

    private(set) var firstSyncState: FirstSyncState = .idle

    /// False until the saved history has been read, so the list can tell a history that is still
    /// loading from a genuinely empty one and never flash "No clips" or the onboarding screen.
    private(set) var hasLoaded = false

    private(set) var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)

    /// Clip records iCloud has delivered so far in a pull that spans several pages; nil otherwise.
    private(set) var syncClipsReceived: Int?

    /// Why sync is in its failed state, when the sync service could tell; nil for any other state.
    private(set) var syncFailureKind: SyncFailureKind?

    /// Clips the last push could not prepare for upload.
    private(set) var waitingClips: [SyncWaitingClip] = []

    /// How far the move to end-to-end encrypted clip content has come; nil until sync reports it.
    private(set) var encryptionStatus: SyncEncryptionStatus?

    /// True when the blobs container or its at-rest protection class failed to set up — synced
    /// image/text blobs may be missing or weaker than `completeUntilFirstUserAuthentication`.
    /// Surfaced to the UI; never silently swallowed.
    private(set) var storageUnavailable = false

    /// True while the history could not be read only because iOS has not made the files
    /// readable yet (the phone was not unlocked since it restarted). Nothing is written, and
    /// sync does not start, until `retryStorageIfUnreadable()` finds the files readable. A
    /// corrupt file is not this state.
    private(set) var isAwaitingFirstUnlock = false

    @ObservationIgnored private var tombstones: [UUID: Date] = [:]
    /// Blobs no clip references any more stay on disk until the snapshot that stopped
    /// referencing them is durable (a sync reconcile, a delete, a clear, retention or the history
    /// cap). Survives a failed write so a later successful snapshot can finish cleanup without
    /// data loss.
    @ObservationIgnored private var blobDeletionsAwaitingSnapshot: Set<ClipboardBlobReference> = []

    private(set) var pendingDeletion: PendingDeletion? {
        didSet { filterCache.invalidate() }
    }

    /// Memoised filtered/sorted view of `items`, invalidated when `items` changes. Internal
    /// (not private) so `ClipStore+Mutations`'s app-only `filteredItems` can access it —
    /// `ClipQuery` isn't compiled into the lean extensions that also build this file.
    @ObservationIgnored var filterCache = ClipFilterCache()
    @ObservationIgnored var tagCache: [String]?

    /// What kept storage from setting up cleanly; `storageUnavailable`, `isAwaitingFirstUnlock`
    /// and `historyWritesDisabled` are derived from it by `refreshStorageState()`.
    private enum StorageFault {
        /// No App Group container: permanent.
        case missingContainer
        /// The blobs folder or a file attribute could not be set up; may pass once files are readable.
        case folderSetup
        /// A history file could not be read; may pass once files are readable.
        case unreadableHistory
        /// The history is corrupt or its recovery failed: fail closed, never retried.
        case unusableHistory
        case keyboardProjection
    }

    @ObservationIgnored private var storageFaults: Set<StorageFault> = []
    @ObservationIgnored private var historyWritesDisabled = false
    /// True from `init(deferHistoryLoad: true)` until `hydrate()` has applied the saved history.
    /// While it is set nothing may write the history file or apply synced state: an empty
    /// in-memory list must never replace the unloaded file.
    @ObservationIgnored private var isHistoryLoadPending = false
    @ObservationIgnored private var hydrateTask: Task<Void, Never>?
    /// A retention pass was requested while the history was still loading; `hydrate()` runs it.
    @ObservationIgnored private var retentionPassOwed = false
    @ObservationIgnored private let appGroupContext: AppGroupContext?
    /// Keeps history storage out of device backups unless the user opted in; nil without an App Group.
    @ObservationIgnored private let backupExclusion: BackupExclusion?
    @ObservationIgnored private var isDrainingShareInbox = false
    @ObservationIgnored private var pendingForegroundTextCapture: PendingForegroundTextCapture?
    @ObservationIgnored private var latestHistoryWriteReceipt: HistorySnapshotWriteReceipt?

    /// Shared snapshot → encode → write pipeline (same type as the macOS store). Writes
    /// immediately (debounce `.zero`) rather than batching, because this file also compiles
    /// into the lean keyboard/share extensions, which risk teardown before a debounced write lands.
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
    /// `UserDefaults.standard` flag set at launch when the history file was missing (a fresh or
    /// restored device) and cleared once the iCloud download position has been dropped. Durable,
    /// so a launch that finds sync off or iCloud signed out still refills when sync next starts.
    nonisolated static let pullPositionRestartPendingKey = "yank.pullPositionRestartPending"
    nonisolated private static let historyWriteOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication
    ]

    private var historyURL: URL? { appGroupContext?.historyURL }
    private var tombstonesURL: URL? { appGroupContext?.tombstonesURL }
    /// All blob filesystem work lives here; the store keeps history, persistence, and sync.
    private var blobStore: IOSClipBlobStore

    /// Settings the user set in-app (App-Group backed). `0` means unlimited / off.
    private var prefs: UserDefaults? { appGroupContext?.defaults }
    private var historyLimit: Int { prefs?.integer(forKey: SettingsKeys.historyLimit) ?? 0 }
    private var retentionDays: Int { prefs?.integer(forKey: SettingsKeys.retentionDays) ?? 0 }

    /// With `deferHistoryLoad` the saved history is not read here: call `hydrate()` and wait for
    /// it before anything captures, syncs or shows the history. The app does this so the load
    /// does not block launch; the default keeps the synchronous load for every other caller.
    init(context: AppGroupContext? = AppGroupContext.live(), deferHistoryLoad: Bool = false) {
        self.appGroupContext = context
        self.backupExclusion = context.map(BackupExclusion.init(context:))
        self.blobStore = IOSClipBlobStore(directory: context?.blobsURL)
        guard let context else {
            storageFaults.insert(.missingContainer)
            refreshStorageState()
            hasLoaded = true
            clipStoreLog.error("App Group container is unavailable; iOS storage is disabled.")
            return
        }
        prepareStorage(context: context, deferHistoryLoad: deferHistoryLoad)
        if !isHistoryLoadPending {
            finishStorageSetup()
        }
    }

    /// Blobs folder, protection classes and the history load, unless the load is deferred to
    /// `hydrate()`. Safe to run again.
    private func prepareStorage(context: AppGroupContext, deferHistoryLoad: Bool) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: context.blobsURL, withIntermediateDirectories: true)
        } catch {
            storageFaults.insert(.folderSetup)
            clipStoreLog.error("Failed to create iOS blobs directory: \(error.localizedDescription)")
        }
        // Data-protection class is the iOS default for App-Group containers, but setting it
        // explicitly keeps blobs encrypted at rest after first unlock while staying readable in
        // the background for sync/extensions. A failure here silently weakens encryption, so it's surfaced.
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: context.blobsURL.path
            )
        } catch {
            storageFaults.insert(.folderSetup)
            clipStoreLog.error("Failed to set iOS blobs data-protection class: \(error.localizedDescription)")
        }
        protectExistingHistoryFiles()
        // A retry clears the faults it owns first, so writes the load needs are not still disabled.
        refreshStorageState()
        if deferHistoryLoad {
            isHistoryLoadPending = true
            return
        }
        let historyFileExisted = historyFileExistsOrIsPending()
        applyLoadResult(
            HistorySnapshotLoader.load(historyURL: context.historyURL, tombstonesURL: context.tombstonesURL),
            historyFileExisted: historyFileExisted
        )
    }

    /// Reads the saved history off the main thread, then applies it and does the launch work
    /// that follows a load. Concurrent and repeated callers share one load.
    func hydrate() async {
        if let hydrateTask {
            await hydrateTask.value
            return
        }
        guard isHistoryLoadPending else { return }
        // Pending is only ever set with a context, so there is always somewhere to load from.
        guard let historyURL, let tombstonesURL else {
            isHistoryLoadPending = false
            hasLoaded = true
            return
        }
        let task = Task { @MainActor in
            // Checked before loading, because the loader replays an interrupted write.
            let historyFileExisted = self.historyFileExistsOrIsPending()
            let result = await Task.detached(priority: .userInitiated) {
                HistorySnapshotLoader.load(historyURL: historyURL, tombstonesURL: tombstonesURL)
            }.value
            // Cleared first, so everything below that persists is not swallowed by the guard.
            self.isHistoryLoadPending = false
            self.applyLoadResult(result, historyFileExisted: historyFileExisted)
            self.finishStorageSetup()
        }
        hydrateTask = task
        await task.value
    }

    /// What follows a setup attempt: backup exclusion, and only when the history loaded the orphan
    /// blob sweep (an empty `items` from a failed load would make every blob look orphaned) and the
    /// keyboard projection, then any retention pass that was requested meanwhile. Marks the
    /// history ready last.
    private func finishStorageSetup() {
        reconcileBackupExclusionInBackground()
        if !historyWritesDisabled {
            sweepOrphanBlobs()
            publishKeyboardProjection()
        }
        hasLoaded = true
        if retentionPassOwed {
            retentionPassOwed = false
            enforceRetentionAndLimit()
        }
    }

    /// Sets the three derived flags from `storageFaults`, notifying observers only on a change.
    private func refreshStorageState() {
        let unavailable = !storageFaults.isEmpty
        if storageUnavailable != unavailable { storageUnavailable = unavailable }
        let awaitingUnlock = storageFaults.contains(.unreadableHistory)
            && storageFaults.isSubset(of: [.unreadableHistory, .folderSetup])
        if isAwaitingFirstUnlock != awaitingUnlock { isAwaitingFirstUnlock = awaitingUnlock }
        historyWritesDisabled = !storageFaults.isDisjoint(
            with: [.missingContainer, .unreadableHistory, .unusableHistory]
        )
    }

    /// Runs storage setup again when the only trouble was files that were not readable yet, as
    /// after a launch before the first unlock. Clears only the faults it owns: a keyboard
    /// projection failure stays unless the projection works now. Does nothing for a corrupt
    /// file or a missing App Group. Returns whether the history is usable afterwards.
    @discardableResult
    func retryStorageIfUnreadable() -> Bool {
        guard isAwaitingFirstUnlock, let appGroupContext else { return false }
        storageFaults.subtract([.folderSetup, .unreadableHistory, .keyboardProjection])
        prepareStorage(context: appGroupContext, deferHistoryLoad: false)
        guard !historyWritesDisabled else { return false }
        finishStorageSetup()
        enforceRetentionAndLimit()
        clipStoreLog.notice("Protected storage became readable; history re-read")
        return true
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
        await hydrate()
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

        let plan = TextCapturePlan.make(for: text)

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
                releaseDeferredBlobDeletions(pendingForegroundTextCapture?.deferredBlobDeletions ?? [])
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

    private func saveImageBlob(_ data: Data, filename: String? = nil) async -> String? {
        await blobStore.saveImage(data, filename: filename)
    }

    /// Import file-per-capture extension handoffs into canonical history. Each entry is
    /// removed only after the canonical snapshot is durably committed; stable entry IDs
    /// make a retry after interruption idempotent.
    @discardableResult
    func drainShareInbox() async -> Set<String> {
        var successfulSources: Set<String> = []
        await hydrate()
        guard !storageUnavailable,
              !historyWritesDisabled,
              !isDrainingShareInbox,
              let inbox = appGroupContext?.shareInbox else { return successfulSources }
        isDrainingShareInbox = true
        defer { isDrainingShareInbox = false }
        do {
            try await Task.detached(priority: .utility) {
                try inbox.sweepKeyboardPreviews()
            }.value
        } catch {
            clipStoreLog.error("Failed to clear stale shared-text previews: \(error.localizedDescription)")
        }
        do {
            let entries = try await Task.detached(priority: .utility) {
                try inbox.recoverablePendingEntries()
            }.value
            for entry in entries {
                do {
                    var didImport = false
                    // The durable record also covers a handoff whose clip was merged by
                    // deduplication or deleted, which leaves no item with the entry's ID.
                    let entryID = entry.id
                    let alreadyProcessed = try await Task.detached(priority: .utility) {
                        try inbox.isProcessed(entryID)
                    }.value
                    if !alreadyProcessed, !items.contains(where: { $0.id == entry.id }) {
                        try await importShareCapture(entry, from: inbox)
                        didImport = true
                    }
                    // Always schedule the current canonical state before removing the
                    // handoff. A prior failed writer operation has already been consumed;
                    // seeing the ID in memory alone is not proof that it reached disk.
                    persist(notify: didImport)
                    try await flushPendingWritesBeforeSuspension()
                    if !alreadyProcessed {
                        try await Task.detached(priority: .utility) {
                            try inbox.markProcessed(entryID)
                        }.value
                    }
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
        let plan = TextCapturePlan.make(for: text)
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
        // A clip waiting out its undo window is not a match: the fresh copy must outlive it.
        guard case .refresh(let existingID) = DuplicateCaptureDecision.decide(
            for: incoming,
            in: items,
            pending: pendingDeletion
        ),
              ClipboardMutations.refreshDuplicateCapture(
                  existingID: existingID,
                  with: incoming,
                  in: &items
              ) else { return nil }
        return existingID
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
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
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
        heldElements = []
        removeItems(ids: Set(items.map(\.id)))
    }

    /// Applies the configured age-retention then history limit (call on launch and after a
    /// settings change). Expired unprotected clips are tombstoned so deletion propagates via
    /// sync; the limit only trims local storage — capped clips stay in the cloud.
    func enforceRetentionAndLimit() {
        guard !isHistoryLoadPending else {
            retentionPassOwed = true
            return
        }
        let result = ClipboardRetention.enforce(
            items: items,
            tombstones: tombstones,
            historyLimit: historyLimit,
            retentionDays: retentionDays,
            now: Date()
        )
        guard result.didChange else { return }
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
        items = result.items
        tombstones = result.tombstones
        persist()
    }

    // MARK: - SyncableStore

    func markSyncStarted() {
        syncStatus = .syncing
        syncFailureKind = nil
        syncClipsReceived = nil
        if firstSyncState != .settled {
            firstSyncState = .syncing
        }
    }

    func markSyncSucceeded(at date: Date) {
        syncStatus = .healthy(lastSynced: date)
        syncFailureKind = nil
        syncClipsReceived = nil
        // The end of a run settles a first sync, also when no page ever applied a change, and
        // clears a failure an earlier run left behind (a remote-change pull never marks a start).
        if firstSyncState != .settled {
            firstSyncState = .settled
        }
    }

    func markSyncProgress(clipsReceived: Int) {
        syncStatus = .syncing
        syncFailureKind = nil
        syncClipsReceived = clipsReceived
        if firstSyncState != .settled {
            firstSyncState = .syncing
        }
    }

    /// A failure without a known cause: the generic "Try again" action applies.
    func markSyncFailed(_ message: String) {
        recordSyncFailure(message: message, kind: nil)
    }

    func markSyncFailure(_ failure: SyncFailure) {
        recordSyncFailure(message: failure.message, kind: failure.kind)
    }

    private func recordSyncFailure(message: String, kind: SyncFailureKind?) {
        syncStatus = .failed(message: message)
        syncFailureKind = kind
        syncClipsReceived = nil
        if firstSyncState != .settled {
            firstSyncState = .failed(message: message)
        }
    }

    func markClipsWaiting(_ clips: [SyncWaitingClip]) {
        guard clips != waitingClips else { return }
        waitingClips = clips
    }

    func markSyncUnavailable(reason: SyncStatus.Reason) {
        syncStatus = .localOnly(reason: reason)
        syncFailureKind = nil
        syncClipsReceived = nil
        // A first sync that never finished must not leave a spinner or a retry screen behind.
        if firstSyncState != .settled {
            firstSyncState = .idle
        }
        waitingClips = []
        encryptionStatus = nil
    }

    func markEncryptionStatus(_ status: SyncEncryptionStatus?) {
        encryptionStatus = status
    }

    var pendingDeletionIDs: Set<UUID> {
        Set(pendingDeletion?.items.map(\.id) ?? [])
    }

    func itemsForSync() -> [ClipboardItem] {
        items + SyncReconcile.tombstoneItems(tombstones)
    }

    private struct ReconcileOutcome {
        let changed: Bool
        let expiredVisibleCount: Int
    }

    /// Applies the canonical state in memory and reports whether anything a snapshot stores
    /// changed. Nothing is assigned when nothing changed, so an echo of this device's own pushes
    /// neither redraws the list nor writes the disk.
    private func applyReconciledInMemory(_ canonical: [ClipboardItem]) -> ReconcileOutcome {
        let result = SyncReconcile.apply(
            canonical: canonical,
            replacing: items,
            historyLimit: historyLimit,
            retentionDays: retentionDays,
            now: Date()
        )
        let changed = SyncReconcile.changesPersistedState(result, items: items, tombstones: tombstones)
        guard changed else { return ReconcileOutcome(changed: false, expiredVisibleCount: 0) }
        if result.cappedVisibleCount > 0 {
            clipStoreLog.info(
                "Reconcile cap dropped \(result.cappedVisibleCount) clip(s); local limit is \(self.historyLimit)."
            )
        }
        if result.expiredVisibleCount > 0 {
            clipStoreLog.info("Reconcile retention expired \(result.expiredVisibleCount) synced clip(s).")
        }
        blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
        items = result.visibleItems
        tombstones = result.tombstones
        return ReconcileOutcome(changed: true, expiredVisibleCount: result.expiredVisibleCount)
    }

    /// A page of a pull that spans several pages is not the end of the sync: the status keeps
    /// reading "Syncing" until the service reports the run finished.
    private func settleFirstSyncUnlessPulling() {
        guard syncClipsReceived == nil else { return }
        markSyncSucceeded(at: Date())
    }

    func applyReconciled(_ canonical: [ClipboardItem]) {
        guard !isHistoryLoadPending else { return }
        let outcome = applyReconciledInMemory(canonical)
        settleFirstSyncUnlessPulling()
        if outcome.changed { persist(notify: outcome.expiredVisibleCount > 0) }
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) throws {
        guard !historyWritesDisabled, !isHistoryLoadPending else { throw PersistenceError.writesDisabled }
        let outcome = applyReconciledInMemory(canonical)
        settleFirstSyncUnlessPulling()
        persist(notify: outcome.expiredVisibleCount > 0)
        try flushPendingWrites()
        releaseDeferredBlobDeletions(blobDeletionsAwaitingSnapshot)
    }

    func applyReconciledAwaitingDurability(_ canonical: [ClipboardItem]) async throws {
        guard !historyWritesDisabled, !isHistoryLoadPending else { throw PersistenceError.writesDisabled }
        guard let historyWriter else { throw PersistenceError.appGroupUnavailable }
        let outcome = applyReconciledInMemory(canonical)
        settleFirstSyncUnlessPulling()
        let batch = blobDeletionsAwaitingSnapshot
        try await historyWriter.awaitDurableSnapshot(
            stateChanged: outcome.changed,
            latestReceipt: latestHistoryWriteReceipt,
            schedule: {
                guard let receipt = persist(notify: outcome.expiredVisibleCount > 0) else {
                    throw PersistenceError.writesDisabled
                }
                return receipt
            }
        )
        releaseDeferredBlobDeletions(batch)
    }

    /// Deletes the batch's blob files that no current clip references, once the snapshot that
    /// stopped referencing them is durable, and forgets exactly that batch.
    private func releaseDeferredBlobDeletions(_ batch: Set<ClipboardBlobReference>) {
        let referencedBlobs = Set(items.flatMap { ClipboardBlobCleanup.references(in: $0) })
        deleteBlobReferences(Array(batch.subtracting(referencedBlobs)))
        blobDeletionsAwaitingSnapshot.subtract(batch)
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
            blobDeletionsAwaitingSnapshot.formUnion(result.blobReferencesToDelete)
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
                storageFaults.insert(.folderSetup)
                clipStoreLog.error("Failed to set iOS history data-protection class: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    /// Whether the history was here before this launch. Checked before loading, because the loader
    /// replays an interrupted write and a write creates the file. A pending write means the
    /// history was here, not restored without it.
    private func historyFileExistsOrIsPending() -> Bool {
        guard let historyURL else { return true }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: historyURL.path)
            || fileManager.fileExists(
                atPath: HistorySnapshotTransaction.transactionURL(for: historyURL).path
            )
    }

    private func applyLoadResult(
        _ result: Result<HistorySnapshotLoader.Snapshot, HistorySnapshotLoader.LoadError>,
        historyFileExisted: Bool
    ) {
        switch result {
        case .success(let snapshot):
            // Nothing may change the history before it is loaded, so this replaces an empty state.
            assert(items.isEmpty && tombstones.isEmpty, "History changed before it finished loading.")
            items = snapshot.items
            tombstones = snapshot.tombstones
            heldElements = snapshot.heldElements
            if !historyFileExisted {
                markPullPositionRestartPending()
            }
        case .failure(let error):
            storageFaults.insert(Self.fault(for: error))
            clipStoreLog.error("Failed to load iOS history snapshot: \(error.localizedDescription)")
        }
        refreshStorageState()
    }

    /// An unreadable file may be readable after the first unlock; every other failure is final.
    private static func fault(for error: HistorySnapshotLoader.LoadError) -> StorageFault {
        switch error {
        case .unreadableHistory, .unreadableTombstones, .unreadableTransaction:
            .unreadableHistory
        case .corruptHistory, .corruptTombstones, .corruptTransaction, .transactionRecoveryFailed:
            .unusableHistory
        }
    }

    /// A missing history file means a fresh install or a device restored from a backup that left
    /// history out. The sync position in the always-backed-up preferences may then claim that
    /// everything was already downloaded, so record that it must be dropped before sync starts,
    /// and write the empty snapshot so the file exists from now on and this fires only once.
    private func markPullPositionRestartPending() {
        UserDefaults.standard.set(true, forKey: Self.pullPositionRestartPendingKey)
        persist(notify: false)
    }

    /// Re-applies the backup choice off the main actor, because it creates folders and writes
    /// file attributes. `BackupExclusion.reconcile()` reads the setting itself when it runs.
    func reconcileBackupExclusionInBackground() {
        // The load may still be replaying an interrupted write to these files; `hydrate()` runs
        // this once it has finished.
        guard let backupExclusion, !isHistoryLoadPending else { return }
        Task.detached(priority: .utility) {
            backupExclusion.reconcile()
        }
    }

    /// Hook for the writer queue: files replaced by a write lose their exclusion flag.
    private var reconcileBackupExclusionAfterWrite: (@Sendable () -> Void)? {
        guard let backupExclusion else { return nil }
        return { backupExclusion.reconcile() }
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

    /// Snapshot on the calling (main) actor, then build and encode both the canonical snapshot
    /// and bounded keyboard projection on the writer's utility queue. The local-change
    /// notification (which schedules a sync push) is thread-agnostic on the receiver.
    @discardableResult
    private func persist(notify: Bool = true) -> HistorySnapshotWriteReceipt? {
        guard !historyWritesDisabled, !isHistoryLoadPending, let historyWriter else {
            clipStoreLog.error("Skipped iOS history save because the on-disk snapshot has not loaded.")
            return nil
        }
        releaseHeldElements()
        let projectionURL = appGroupContext?.keyboardProjectionURL
        let receipt = historyWriter.scheduleSave(
            items: items,
            preservedElements: heldElements,
            tombstones: tombstones,
            keyboardProjectionURL: projectionURL,
            afterSuccessfulWrite: reconcileBackupExclusionAfterWrite,
            onKeyboardProjectionError: { error in
                clipStoreLog.error("Failed to publish keyboard history: \(error.localizedDescription)")
            }
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
                    self?.storageFaults.insert(.keyboardProjection)
                    self?.refreshStorageState()
                }
            },
            afterWrite: reconcileBackupExclusionAfterWrite
        )
    }
}
