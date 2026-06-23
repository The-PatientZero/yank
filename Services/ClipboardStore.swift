import Foundation
import AppKit
import Observation

private enum ClipboardStoreFileSecurity {
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600
    static let fileProtection: FileProtectionType = .complete
    static let writeOptions: Data.WritingOptions = .atomic

    static var directoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: directoryPermissions]
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: writeOptions)
        try applyPrivateFileAttributes(to: url)
    }

    static func writeText(_ text: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try write(Data(text.utf8), to: url)
        }.value
    }

    static func applyPrivateFileAttributes(to url: URL) throws {
        try PrivateFileAttributes.apply(to: url, permissions: filePermissions, protection: fileProtection)
    }

    static func applyPrivateDirectoryAttributes(to url: URL) throws {
        try PrivateFileAttributes.apply(to: url, permissions: directoryPermissions, protection: fileProtection)
    }

    static func secureExistingFiles(in directories: [URL]) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey]
            for directory in directories {
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    try? applyPrivateFileAttributes(to: url)
                }
            }
        }
    }
}

/// Manages persistent storage of clipboard history
@MainActor
@Observable
final class ClipboardStore {
    var items: [ClipboardItem] = [] {
        didSet {
            filterCache = nil
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

    private(set) var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)

    @ObservationIgnored private var tombstones: [UUID: Date] = [:]
    @ObservationIgnored private var historyWritesDisabled = false

    private(set) var pendingDeletion: PendingDeletion? {
        didSet { filterCache = nil }
    }

    /// Bumped on every `items` mutation so views can observe "something changed" with an
    /// O(1) integer compare instead of diffing the whole array each time.
    private(set) var changeToken = 0

    /// Memoised filtered/sorted view of `items`; invalidated whenever `items` changes
    /// (see `filteredItems`). Keeps the window's per-render recomputation O(1) on a hit.
    @ObservationIgnored private var filterCache: (query: String, tag: String?, result: [ClipboardItem])?

    /// Memoised `allTags`, recomputed in `items.didSet` rather than on every read. Views
    /// (the tag chip bar / filter menu) read `allTags` several times per render and
    /// keystroke, and the source list does not change between renders.
    @ObservationIgnored private var cachedTags: [String] = []

    private var maxItems: Int { captureSettings.historyLimit }
    private let fileManager = FileManager.default
    private let storageDirectoryOverride: URL?

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
    @ObservationIgnored private lazy var historyWriter = HistorySnapshotWriter(
        historyURL: historyFileURL,
        tombstonesURL: tombstonesFileURL,
        writeOptions: ClipboardStoreFileSecurity.writeOptions,
        filePermissions: ClipboardStoreFileSecurity.filePermissions,
        fileProtection: ClipboardStoreFileSecurity.fileProtection,
        debounce: .milliseconds(300),
        queueLabel: "com.yank.save",
        onError: { error in Log.store.error("Failed to save history: \(error.localizedDescription)") }
    )
    
    private var storageDirectory: URL {
        if let storageDirectoryOverride { return storageDirectoryOverride }
        // Application Support effectively always exists for a Mac app, but never trap the
        // app at launch if the lookup is empty (sandbox/odd-volume edge) — fail soft to tmp.
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Yank", isDirectory: true)
    }
    
    private var historyFileURL: URL {
        storageDirectory.appendingPathComponent("history.json")
    }
    
    private var imagesDirectory: URL {
        storageDirectory.appendingPathComponent("images", isDirectory: true)
    }
    
    private var textsDirectory: URL {
        storageDirectory.appendingPathComponent("texts", isDirectory: true)
    }

    private var richDirectory: URL {
        storageDirectory.appendingPathComponent("rich", isDirectory: true)
    }

    private var tombstonesFileURL: URL {
        storageDirectory.appendingPathComponent("tombstones.json")
    }

    init(settings: CaptureSettings, storageDirectory: URL? = nil) {
        self.captureSettings = settings
        self.storageDirectoryOverride = storageDirectory
        ensureDirectoriesExist()
        loadSnapshot()
        pruneExpired()
        hasLoaded = true
    }

    /// Apply age retention, the local history cap, and tombstone pruning. Explicit calls
    /// (launch, `captureSettings` change) bypass the capture-path time gate.
    func pruneExpired() {
        if applyRetentionAndLimit(now: Date()) { persist() }
    }
    
    // MARK: - Public API
    
    func add(_ item: ClipboardItem, richArchive: PasteboardArchive? = nil) {
        // History-wide dedup: an identical inline-text copy floats up instead of duplicating.
        if item.type == .text, item.textFilename == nil, !item.isTruncated,
           let content = item.textContent,
           let existing = items.first(where: { $0.type == .text && $0.textFilename == nil && $0.textContent == content }) {
            moveToTop(existing)
            signalCapture()   // a re-copy still confirms — the user pressed ⌘C
            return
        }

        var stamped = item
        // Persist the full pasteboard archive only now that we know the item is being
        // inserted (not deduped) — so a rejected copy never orphans a rich file.
        if let archive = richArchive, let filename = saveRichArchive(archive) {
            stamped.richFilename = filename
        }
        if stamped.deviceOrigin.isEmpty { stamped.deviceOrigin = DeviceIdentity.current }
        tombstones.removeValue(forKey: stamped.id)
        items.insert(stamped, at: 0)

        _ = applyHistoryLimit()

        // Age-based expiry is a day-granularity
        // sweep, so it need not run on every copy.
        _ = sweepExpiredOnCapture(now: Date())
        persist()
        signalCapture()
    }

    /// Fan a capture out to every confirmation channel: the non-visual `Feedback` cue (haptic +
    /// sound) and the view-layer pulse signal the menu-bar glyph observes. The single capture
    /// acknowledgement point — both `add` exit paths route through it.
    private func signalCapture() {
        Feedback.emit(.capture)
        NotificationCenter.default.post(name: .yankDidCapture, object: nil)
    }

    func delete(_ item: ClipboardItem) {
        softDelete([item])
    }

    func deleteItems(_ deleteItems: [ClipboardItem]) {
        softDelete(deleteItems)
    }

    private func softDelete(_ toDelete: [ClipboardItem]) {
        commitPendingDeleteIfNeeded()
        pendingDeletion = PendingDeletion(items: toDelete, enqueuedAt: Date())
        Feedback.emit(.delete)
    }

    func undoPendingDelete() {
        pendingDeletion = nil
    }

    func commitPendingDeleteIfNeeded() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        let ids = Set(pending.items.map(\.id))
        let result = ClipboardMutations.removeItems(ids: ids, from: items)
        deleteBlobReferences(result.blobReferencesToDelete)
        recordTombstones(result.tombstones)
        items = result.items
        persist()
    }

    func togglePin(for item: ClipboardItem) {
        ClipboardMutations.togglePin(&items, id: item.id)
        persist()
        Feedback.emit(.pin)
    }

    func toggleBookmark(for item: ClipboardItem) {
        ClipboardMutations.toggleBookmark(&items, id: item.id)
        persist()
    }

    /// Memoised tags, recomputed only when `items` changes. Same shape the
    /// views already read, so call sites are unchanged.
    var allTags: [String] { cachedTags }

    /// Search / `#tag` / `@app`-filtered, pinned-first — memoised until `items` changes,
    /// so the window's many per-render reads (header count, stream, sectioning, and the
    /// selection summaries derived from it) share one filter + sort instead of recomputing.
    func filteredItems(search: String, activeTag: String?) -> [ClipboardItem] {
        if let cache = filterCache, cache.query == search, cache.tag == activeTag {
            return cache.result
        }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pendingDeletion)
        let result = ClipQuery.filter(visible, search: search, activeTag: activeTag)
        filterCache = (search, activeTag, result)
        return result
    }

    func addTag(_ tag: String, to item: ClipboardItem) {
        ClipboardMutations.addTag(tag, id: item.id, in: &items)
        persist()
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        ClipboardMutations.removeTag(tag, id: item.id, in: &items)
        persist()
    }

    func setOCRText(_ text: String, for item: ClipboardItem) {
        ClipboardMutations.setOCRText(text, id: item.id, in: &items)
        persist()
    }

    /// Move an item to the top of the list (most recent position)
    func moveToTop(_ item: ClipboardItem) {
        if ClipboardMutations.moveToTop(item.id, in: &items) { persist() }
    }

    func moveToTop(_ selectedItems: [ClipboardItem]) {
        let ids = selectedItems.map(\.id)
        if ClipboardMutations.moveToTop(ids, in: &items) { persist() }
    }

    func clear() {
        let result = ClipboardMutations.removeItems(ids: Set(items.map(\.id)), from: items)
        deleteBlobReferences(result.blobReferencesToDelete)
        recordTombstones(result.tombstones)
        items = result.items
        persist()
    }
    
    func image(for item: ClipboardItem) -> NSImage? {
        guard item.type == .image else { return nil }
        return Self.image(at: blobURL(for: item))
    }

    static func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
    
    /// Copy each image clip's blob into `folder` as `image-0001.png`, `image-0002.png`, …
    /// Moves the blob-copy `FileManager` I/O out of the SwiftUI view and into
    /// the store, which owns the blob layout. Non-image items are skipped; an item whose
    /// blob is missing is reported rather than silently dropped. Returns the number of
    /// images written so the caller can report progress.
    @discardableResult
    func exportImages(_ items: [ClipboardItem], to folder: URL) throws(ImageExportError) -> Int {
        var written = 0
        for item in items where item.type == .image {
            guard let source = blobURL(for: item) else {
                throw .missingBlob(itemID: item.id)
            }
            written += 1
            let fileName = "image-\(String(format: "%04d", written)).png"
            let destination = folder.appendingPathComponent(fileName)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw .copyFailed(itemID: item.id, underlying: error)
            }
        }
        return written
    }

    func saveImage(_ data: Data) -> String? {
        let filename = UUID().uuidString + ".png"
        let url = imagesDirectory.appendingPathComponent(filename)
        
        do {
            try ClipboardStoreFileSecurity.write(data, to: url)
            return filename
        } catch {
            Log.store.error("Failed to save image: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Persist a full pasteboard archive (binary plist) and return its filename (#11).
    func saveRichArchive(_ archive: PasteboardArchive) -> String? {
        let filename = UUID().uuidString + ".plist"
        let url = richDirectory.appendingPathComponent(filename)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try ClipboardStoreFileSecurity.write(encoder.encode(archive), to: url)
            return filename
        } catch {
            Log.store.error("Failed to save rich archive: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load the full pasteboard archive for an item, if it has one.
    func richArchive(for item: ClipboardItem) -> PasteboardArchive? {
        guard let url = richArchiveURL(for: item) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(PasteboardArchive.self, from: data)
    }

    func richArchiveAsync(for item: ClipboardItem) async -> PasteboardArchive? {
        guard let url = richArchiveURL(for: item) else { return nil }
        do {
            return try await ClipboardPayloadLoader.richArchive(for: item, blobURL: url)
        } catch {
            Log.store.error("Failed to load rich archive: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save large text to a file and return the filename
    func saveText(_ text: String) -> String? {
        let filename = UUID().uuidString + ".txt"
        let url = textsDirectory.appendingPathComponent(filename)
        
        do {
            try ClipboardStoreFileSecurity.write(Data(text.utf8), to: url)
            return filename
        } catch {
            Log.store.error("Failed to save text file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save large text off the main actor and return the filename. Used by clipboard
    /// capture, where a multi-MB write should never stall the menu-bar UI.
    func saveTextAsync(_ text: String) async -> String? {
        let filename = UUID().uuidString + ".txt"
        let url = textsDirectory.appendingPathComponent(filename)

        do {
            try await ClipboardStoreFileSecurity.writeText(text, to: url)
            return filename
        } catch {
            Log.store.error("Failed to save text file: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Load full text content from file (lazy loading for large text)
    func fullText(for item: ClipboardItem) -> String? {
        guard let filename = item.textFilename else { return item.textContent }
        guard let url = SyncBlobPolicy.containedURL(directory: textsDirectory, filename: filename, kind: .text) else {
            return item.textContent
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.store.error("Failed to load text file: \(error.localizedDescription)")
            return item.textContent
        }
    }

    func fullTextAsync(for item: ClipboardItem) async -> String? {
        let url = blobURL(for: item)
        do {
            return try await ClipboardPayloadLoader.fullText(for: item, blobURL: url)
        } catch {
            Log.store.error("Failed to load text file: \(error.localizedDescription)")
            return item.textContent
        }
    }

    func imagePNGDataAsync(for item: ClipboardItem) async -> Data? {
        do {
            return try await ClipboardPayloadLoader.imagePNGData(for: item, blobURL: blobURL(for: item))
        } catch {
            Log.store.error("Failed to load image blob: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Load a chunk of text content, reading only what's necessary
    func textChunk(for item: ClipboardItem, charCount: Int) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        Self.textChunk(for: item, textURL: blobURL(for: item), charCount: charCount)
    }

    nonisolated static func textChunk(
        for item: ClipboardItem,
        textURL: URL?,
        charCount: Int
    ) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        if let url = textURL, item.textFilename != nil {
            return TextChunkReader.page(for: item, textURL: url, charCount: charCount) { error in
                Log.store.error("Failed to read text chunk: \(error.localizedDescription)")
            }
        }
        return TextChunkReader.page(for: item, textURL: nil, charCount: charCount)
    }
    
    /// Per-id memo of the disk-stat result for file-backed clips. A clip's blob is immutable
    /// for its id, so its size never changes; this keeps repeated reads from a SwiftUI body
    /// (e.g. the multi-selection size summary) off the filesystem.
    @ObservationIgnored private var sizeCache: [UUID: Int] = [:]

    /// Get the total size of an item (in bytes) for UI display.
    func itemSize(for item: ClipboardItem) -> Int? {
        if let original = item.originalSizeBytes { return original }

        switch item.type {
        case .text:
            guard let filename = item.textFilename else { return item.textContent?.utf8.count }
            guard let url = SyncBlobPolicy.containedURL(directory: textsDirectory, filename: filename, kind: .text) else {
                return nil
            }
            return cachedFileSize(id: item.id, url: url)
        case .image:
            guard let filename = item.imageFilename else { return nil }
            guard let url = SyncBlobPolicy.containedURL(directory: imagesDirectory, filename: filename, kind: .image) else {
                return nil
            }
            return cachedFileSize(id: item.id, url: url)
        }
    }

    private func cachedFileSize(id: UUID, url: URL) -> Int? {
        if let cached = sizeCache[id] { return cached }
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int else { return nil }
        sizeCache[id] = size
        return size
    }
    
    // MARK: - Private
    
    private func ensureDirectoriesExist() {
        // Failing to create the storage tree means history cannot be persisted this
        // session — captures would be silently lost on quit. Surface it explicitly via
        // `storageUnavailable` and log with context instead of swallowing.
        let directories = [storageDirectory, imagesDirectory, textsDirectory, richDirectory]
        for directory in directories {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: ClipboardStoreFileSecurity.directoryAttributes
                )
                try ClipboardStoreFileSecurity.applyPrivateDirectoryAttributes(to: directory)
            } catch {
                storageUnavailable = true
                Log.store.error(
                    "Failed to create storage directory \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
        ClipboardStoreFileSecurity.secureExistingFiles(in: directories)
        // Keep clip history (which can hold secrets) out of Time Machine / iCloud backups;
        // excluding the parent covers the whole subtree. CloudKit sync is the intended
        // cross-device/restore path for clips the user wants to keep.
        excludeFromBackup(storageDirectory)
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
    
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
    
    private func deleteBlobReferences(_ references: [ClipboardBlobReference]) {
        for reference in references {
            guard let url = blobURL(for: reference) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func blobURL(for reference: ClipboardBlobReference) -> URL? {
        switch reference.kind {
        case .image:
            SyncBlobPolicy.containedURL(directory: imagesDirectory, filename: reference.filename, kind: .image)
        case .text:
            SyncBlobPolicy.containedURL(directory: textsDirectory, filename: reference.filename, kind: .text)
        case .rich:
            SyncBlobPolicy.containedURL(directory: richDirectory, filename: reference.filename, kind: .rich)
        }
    }

    private func richArchiveURL(for item: ClipboardItem) -> URL? {
        guard let filename = item.richFilename else { return nil }
        return SyncBlobPolicy.containedURL(directory: richDirectory, filename: filename, kind: .rich)
    }

    @discardableResult
    private func applyHistoryLimit() -> Bool {
        guard maxItems > 0, items.count > maxItems else { return false }
        let result = ClipboardRetention.cap(items, limit: maxItems)
        guard result.items != items else { return false }
        deleteBlobReferences(result.blobReferencesToDelete)
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
        deleteBlobReferences(result.blobReferencesToDelete)
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
    private func recordTombstones(_ newTombstones: [UUID: Date]) {
        for (id, date) in newTombstones {
            tombstones[id] = date
        }
    }

    private func persist(notify: Bool = true) {
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

    // MARK: - Sync support

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
                "Reconcile cap dropped \(result.cappedVisibleCount) synced clip(s) — local history limit is \(self.maxItems)."
            )
        }
        if result.expiredVisibleCount > 0 {
            Log.store.info("Reconcile retention expired \(result.expiredVisibleCount) synced clip(s).")
        }
        deleteBlobReferences(result.blobReferencesToDelete)
        items = result.visibleItems
        tombstones = result.tombstones
        persist(notify: result.expiredVisibleCount > 0)
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) {
        applyReconciled(canonical)
        flushPendingWrites()
    }

    func blobURL(for item: ClipboardItem) -> URL? {
        if let filename = item.imageFilename {
            return SyncBlobPolicy.containedURL(directory: imagesDirectory, filename: filename, kind: .image)
        }
        if let filename = item.textFilename {
            return SyncBlobPolicy.containedURL(directory: textsDirectory, filename: filename, kind: .text)
        }
        return nil
    }

    func blobURL(for reference: SyncBlobReference) -> URL? {
        let directory = syncDirectory(for: reference.kind)
        return reference.containedURL(in: directory)
    }

    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws {
        let directory = syncDirectory(for: reference.kind)
        guard let url = reference.containedURL(in: directory) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        do {
            try await SyncBlobStorage.write(
                data,
                to: url,
                maxBytes: reference.maximumBytes,
                writeOptions: ClipboardStoreFileSecurity.writeOptions,
                filePermissions: ClipboardStoreFileSecurity.filePermissions,
                fileProtection: ClipboardStoreFileSecurity.fileProtection
            )
        } catch {
            Log.store.error("Failed to write synced blob \(reference.filename, privacy: .public): \(error.localizedDescription)")
            throw error
        }
    }

    func deleteBlob(_ reference: SyncBlobReference) {
        let directory = syncDirectory(for: reference.kind)
        guard let url = reference.containedURL(in: directory) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func syncDirectory(for kind: SyncBlobKind) -> URL {
        switch kind {
        case .image:
            imagesDirectory
        case .text:
            textsDirectory
        case .rich:
            richDirectory
        }
    }

}

extension ClipboardStore: SyncableStore {}

/// Failure modes for `ClipboardStore.exportImages(_:to:)`.
enum ImageExportError: Error, LocalizedError {
    case missingBlob(itemID: UUID)
    case copyFailed(itemID: UUID, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingBlob:
            "An image could not be found in the clipboard store."
        case .copyFailed(_, let underlying):
            "Failed to save an image: \(underlying.localizedDescription)"
        }
    }
}
