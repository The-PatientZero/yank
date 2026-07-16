import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

private let syncLog = Logger(subsystem: "com.thepatientzero.yank", category: "sync")

// `SyncableStore` lives in `Sources/YankCore/SyncableStore.swift` (no CloudKit import) so
// the iOS extensions can use the store without linking CloudKit.

private enum CloudKitSyncError: LocalizedError {
    case missingBlobAsset(String)
    case partialRecordFailures(Int)

    var errorDescription: String? {
        switch self {
        case .missingBlobAsset(let filename):
            "Synced blob \(filename) is missing from CloudKit."
        case .partialRecordFailures(let count):
            "CloudKit could not return \(count) changed record(s). Sync will retry."
        }
    }
}

/// Pure `ClipboardItem ⇄ CKRecord` mapping for scalar fields. Blobs attach as `CKAsset`.
/// No network — round-trips offline, so it is unit-tested directly.
enum ClipboardCloudMapping {
    static let recordType = "ClipboardItem"

    enum Key {
        static let type = "type"
        static let timestamp = "timestamp"
        static let sourceApp = "sourceApp"
        static let textContent = "textContent"
        static let textFilename = "textFilename"
        static let imageFilename = "imageFilename"
        static let isPinned = "isPinned"
        static let isBookmarked = "isBookmarked"
        static let tags = "tags"
        static let ocrText = "ocrText"
        static let isTruncated = "isTruncated"
        static let originalSizeBytes = "originalSizeBytes"
        static let modifiedAt = "modifiedAt"
        static let deletedAt = "deletedAt"
        static let deviceOrigin = "deviceOrigin"
        static let blob = "blob"
        static let hasRichContent = "hasRichContent"
        static let searchIndex = "searchIndex"
        static let aiTags = "aiTags"
        static let aiTitle = "aiTitle"
        static let aiEnrichedAt = "aiEnrichedAt"
    }

    static func record(from item: ClipboardItem, in zoneID: CKRecordZone.ID, blobURL: URL? = nil) -> CKRecord? {
        guard let filenames = validatedBlobFilenames(
            type: item.type,
            textFilename: item.textFilename,
            imageFilename: item.imageFilename
        ), blobURL == nil || filenames.textFilename != nil || filenames.imageFilename != nil else {
            return nil
        }

        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record[Key.type] = item.type.rawValue
        record[Key.timestamp] = item.timestamp
        record[Key.sourceApp] = item.sourceApp
        record[Key.textContent] = item.textContent
        record[Key.textFilename] = filenames.textFilename
        record[Key.imageFilename] = filenames.imageFilename
        record[Key.isPinned] = item.isPinned ? 1 : 0
        record[Key.isBookmarked] = item.isBookmarked ? 1 : 0
        record[Key.tags] = item.tags
        record[Key.ocrText] = item.ocrText
        record[Key.isTruncated] = item.isTruncated ? 1 : 0
        record[Key.originalSizeBytes] = item.originalSizeBytes
        record[Key.searchIndex] = item.searchIndex
        record[Key.aiTags] = item.aiTags
        record[Key.aiTitle] = item.aiTitle
        record[Key.aiEnrichedAt] = item.aiEnrichedAt
        record[Key.modifiedAt] = item.modifiedAt
        record[Key.deletedAt] = item.deletedAt
        record[Key.deviceOrigin] = item.deviceOrigin
        record[Key.hasRichContent] = item.hasRichContent ? 1 : 0
        if let blobURL {
            record[Key.blob] = CKAsset(fileURL: blobURL)
        }
        return record
    }

    static func item(from record: CKRecord) -> ClipboardItem? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let typeRaw = record[Key.type] as? String,
              let type = ClipboardItemType(rawValue: typeRaw),
              let timestamp = record[Key.timestamp] as? Date,
              let modifiedAt = record[Key.modifiedAt] as? Date else { return nil }
        let rawTextFilename = record[Key.textFilename] as? String
        let rawImageFilename = record[Key.imageFilename] as? String
        guard let filenames = validatedBlobFilenames(
            type: type,
            textFilename: rawTextFilename,
            imageFilename: rawImageFilename
        ) else {
            return nil
        }
        let bool: (String) -> Bool = { ((record[$0] as? Int) ?? 0) != 0 }
        return ClipboardItem(
            id: id,
            type: type,
            timestamp: timestamp,
            sourceApp: record[Key.sourceApp] as? String,
            textContent: record[Key.textContent] as? String,
            textFilename: filenames.textFilename,
            imageFilename: filenames.imageFilename,
            hasRichContent: bool(Key.hasRichContent),
            isPinned: bool(Key.isPinned),
            isBookmarked: bool(Key.isBookmarked),
            tags: record[Key.tags] as? [String] ?? [],
            ocrText: record[Key.ocrText] as? String,
            isTruncated: bool(Key.isTruncated),
            originalSizeBytes: record[Key.originalSizeBytes] as? Int,
            searchIndex: record[Key.searchIndex] as? String,
            aiTags: record[Key.aiTags] as? [String] ?? [],
            aiTitle: record[Key.aiTitle] as? String,
            aiEnrichedAt: record[Key.aiEnrichedAt] as? Date,
            modifiedAt: modifiedAt,
            deletedAt: record[Key.deletedAt] as? Date,
            deviceOrigin: record[Key.deviceOrigin] as? String ?? ""
        )
    }

    private static func validatedBlobFilenames(
        type: ClipboardItemType,
        textFilename: String?,
        imageFilename: String?
    ) -> (textFilename: String?, imageFilename: String?)? {
        guard textFilename == nil || imageFilename == nil else { return nil }

        if let textFilename {
            guard type == .text,
                  let reference = SyncBlobReference(filename: textFilename, kind: .text) else { return nil }
            return (reference.filename, nil)
        }

        if let imageFilename {
            guard type == .image,
                  let reference = SyncBlobReference(filename: imageFilename, kind: .image) else { return nil }
            return (nil, reference.filename)
        }

        return (nil, nil)
    }
}

/// Outcome of `CloudKitSyncService.start()`: sync came up, or it failed with a
/// user-presentable message.
public enum CloudKitSyncStartResult: Equatable, Sendable {
    case started
    case failed(message: String)
}

/// Plain-data view of one page of zone changes, so the sync engine can be exercised with a
/// fake — `CKDatabase.RecordZoneChanges` is not constructible outside CloudKit. It holds
/// non-`Sendable` `CKRecord`s but never crosses an actor boundary: the `CloudKitDatabase`
/// seam below is `@MainActor`, so records stay on the sync service's actor exactly as they
/// did when the service called `CKDatabase` directly.
struct CloudKitZoneChanges {
    var changedRecords: [CKRecord]
    var deletedRecordNames: [String]
    var failedRecordNames: [String] = []
    var changeToken: CKServerChangeToken?
    var moreComing: Bool
}

/// The CloudKit operations `CloudKitSyncService` depends on, abstracted behind a seam (DIP)
/// so the orchestration — ensure zone/subscription → paginated pull → `ClipboardMerge` →
/// apply → watermarked push — is unit-tested against an in-memory fake instead of a live
/// network. The live conformance is
/// `CKDatabase`; tests substitute a fake. Declared `@MainActor` so `CKRecord` value types
/// stay on the service's actor (matching the prior direct-`CKDatabase` calls) — no
/// `Sendable` laundering of CloudKit types is required.
@MainActor
protocol CloudKitDatabase {
    func ensureZone(_ zoneID: CKRecordZone.ID) async throws
    func ensureSubscription(id subscriptionID: String) async throws
    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges
    func saveRecords(_ records: [CKRecord]) async throws
}

/// Live CloudKit conformance. The idempotent "subscription already exists" handling and the
/// `RecordZoneChanges` → `CloudKitZoneChanges` flattening live here so the orchestration in
/// `CloudKitSyncService` stays transport-agnostic and testable.
@MainActor
extension CKDatabase: CloudKitDatabase {
    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = try await save(CKRecordZone(zoneID: zoneID))
    }

    func ensureSubscription(id subscriptionID: String) async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Subscription already exists — idempotent.
        }
    }

    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        let changes = try await recordZoneChanges(inZoneWith: zoneID, since: token)
        var changedRecords: [CKRecord] = []
        var failedRecordNames: [String] = []
        changedRecords.reserveCapacity(changes.modificationResultsByID.count)
        failedRecordNames.reserveCapacity(changes.modificationResultsByID.count)
        for (recordID, result) in changes.modificationResultsByID {
            switch result {
            case .success(let modification):
                changedRecords.append(modification.record)
            case .failure:
                failedRecordNames.append(recordID.recordName)
            }
        }
        return CloudKitZoneChanges(
            changedRecords: changedRecords,
            deletedRecordNames: changes.deletions.map { $0.recordID.recordName },
            failedRecordNames: failedRecordNames.sorted(),
            changeToken: changes.changeToken,
            moreComing: changes.moreComing
        )
    }

    func saveRecords(_ records: [CKRecord]) async throws {
        _ = try await modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
    }
}

/// Syncs the local store with the user's CloudKit private database.
/// Offline-first: the local store is the source of truth, CloudKit the transport.
/// Conflicts resolve through `ClipboardMerge` (last-writer-wins); deletes propagate via tombstones.
@MainActor
public final class CloudKitSyncService {
    private let database: any CloudKitDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
    private let subscriptionID = "yank-changes"
    private let defaults: UserDefaults
    private let tokenKey: String
    private let pushWatermarkKey: String
    private weak var store: SyncableStore?
    private var changeToken: CKServerChangeToken?
    private var localChangeObserver: NSObjectProtocol?
    private var scheduledPush: Task<Void, Never>?

    /// Live entry point: binds to the container's private database. `CKContainer(identifier:)`
    /// hard-traps on a binary not provisioned for the container, so callers must gate on
    /// provisioning before constructing the service (see `AppDelegate`).
    public convenience init(containerIdentifier: String, store: SyncableStore, defaults: UserDefaults = .standard) {
        self.init(
            containerIdentifier: containerIdentifier,
            store: store,
            database: CKContainer(identifier: containerIdentifier).privateCloudDatabase,
            defaults: defaults
        )
    }

    /// Seam-injecting initializer — tests pass an in-memory `CloudKitDatabase` fake.
    init(
        containerIdentifier: String,
        store: SyncableStore,
        database: any CloudKitDatabase,
        defaults: UserDefaults = .standard
    ) {
        self.database = database
        self.store = store
        self.defaults = defaults
        self.tokenKey = "cloudkit.changeToken.\(containerIdentifier)"
        self.pushWatermarkKey = "cloudkit.lastPushedModifiedAt.\(containerIdentifier)"
        self.changeToken = Self.loadToken(from: defaults, key: tokenKey)
    }

    // `isolated deinit` runs cleanup on the main actor (the runtime hops if the last release lands
    // off-main), so it never traps the way `MainActor.assumeIsolated` would — important here, since
    // this service is captured by its own async start/push tasks and can be released off-main.
    isolated deinit {
        scheduledPush?.cancel()
        if let localChangeObserver {
            NotificationCenter.default.removeObserver(localChangeObserver)
        }
    }

    /// Mark sync as unavailable on the store (e.g. no iCloud account, container not provisioned),
    /// without attempting a network round-trip.
    public func reportUnavailable(reason: SyncStatus.Reason) {
        store?.markSyncUnavailable(reason: reason)
    }

    /// One-shot bring-up: ensure zone + push subscription, pull remote, push local.
    @discardableResult
    public func start() async -> CloudKitSyncStartResult {
        store?.markSyncStarted()
        do {
            try await ensureZone()
            try await ensureSubscription()
            try await pull()
            startObservingLocalChanges()
            try await pushLocal()
            store?.markSyncSucceeded(at: Date())
            return .started
        } catch {
            let message = error.localizedDescription
            syncLog.error("start failed: \(message, privacy: .public)")
            store?.markSyncFailed(message)
            return .failed(message: message)
        }
    }

    private func startObservingLocalChanges() {
        guard localChangeObserver == nil else { return }
        localChangeObserver = NotificationCenter.default.addObserver(
            forName: .yankLocalStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.schedulePush()
            }
        }
    }

    /// Called from the silent push handler to fold in remote changes.
    @discardableResult
    public func handleRemoteChange() async -> Bool {
        do {
            let recoveredExpiredToken = try await pull()
            if recoveredExpiredToken {
                try await pushLocal()
            }
            store?.markSyncSucceeded(at: Date())
            return true
        } catch {
            let message = error.localizedDescription
            syncLog.error("remote pull failed: \(message, privacy: .public)")
            store?.markSyncFailed(message)
            return false
        }
    }

    private func schedulePush() {
        scheduledPush?.cancel()
        scheduledPush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await self?.pushLocal()
                self?.store?.markSyncSucceeded(at: Date())
            } catch {
                let message = error.localizedDescription
                syncLog.error("local push failed: \(message, privacy: .public)")
                self?.store?.markSyncFailed(message)
            }
        }
    }

    private func ensureZone() async throws {
        try await database.ensureZone(zoneID)
    }

    private func ensureSubscription() async throws {
        try await database.ensureSubscription(id: subscriptionID)
    }

    /// Returns true when recovery discarded the push watermark and callers should re-push local state.
    @discardableResult
    private func pull() async throws -> Bool {
        do {
            try await pullUsingCurrentToken()
            return false
        } catch {
            guard Self.isExpiredChangeTokenError(error) else { throw error }
            syncLog.info("CloudKit change token expired; retrying from the beginning.")
            changeToken = nil
            persistToken(nil)
            lastPushedModifiedAt = nil
            try await pullUsingCurrentToken()
            return true
        }
    }

    private func pullUsingCurrentToken() async throws {
        var remote: [ClipboardItem] = []
        var downloadedBlobs: Set<SyncBlobReference> = []
        var token = changeToken
        var moreComing = true
        do {
            while moreComing {
                let changes = try await database.fetchZoneChanges(zoneID, since: token)
                guard changes.failedRecordNames.isEmpty else {
                    throw CloudKitSyncError.partialRecordFailures(changes.failedRecordNames.count)
                }
                for record in changes.changedRecords {
                    guard let item = ClipboardCloudMapping.item(from: record) else { continue }
                    if let store, let blob = try await downloadBlobIfNeeded(from: record, for: item, into: store) {
                        downloadedBlobs.insert(blob)
                    }
                    remote.append(item)
                }
                for recordName in changes.deletedRecordNames {
                    if let id = UUID(uuidString: recordName) {
                        remote.append(tombstone(id))
                    }
                }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            guard let store else { return }
            let local = store.itemsForSync()
            let reconciled = ClipboardMerge.reconcile(local, remote)
            try store.applyReconciledDurably(reconciled)
            deleteDownloadedBlobsNotReferenced(downloadedBlobs, in: store)
            changeToken = token
            persistToken(token)
        } catch {
            if let store {
                deleteDownloadedBlobsNotReferenced(downloadedBlobs, in: store)
            }
            throw error
        }
    }

    private nonisolated static func isExpiredChangeTokenError(_ error: any Error) -> Bool {
        if let cloudKitError = error as? CKError {
            return cloudKitError.code == .changeTokenExpired
        }

        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain
            && nsError.code == CKError.Code.changeTokenExpired.rawValue
    }

    private func pushLocal() async throws {
        guard let store else { return }
        let local = store.itemsForSync()
        let dirtyItems = Self.itemsNeedingPush(local, since: lastPushedModifiedAt)
        guard !dirtyItems.isEmpty else { return }

        let prepared = Self.preparePushRecords(dirtyItems, in: zoneID) { item in
            item.isDeleted ? nil : existingBlobURL(for: item)
        }
        for skippedID in prepared.skippedItemIDs {
            syncLog.error("skipping clip with invalid sync blob metadata: \(skippedID.uuidString, privacy: .public)")
        }
        guard !prepared.records.isEmpty else { return }
        for batch in prepared.records.map(\.record).chunked(into: 100) {
            try await database.saveRecords(batch)
        }
        lastPushedModifiedAt = Self.pushedWatermark(afterPushing: prepared.records)
    }

    nonisolated static func itemsNeedingPush(_ items: [ClipboardItem], since watermark: Date?) -> [ClipboardItem] {
        guard let watermark else { return items }
        return items.filter { $0.modifiedAt > watermark }
    }

    struct PreparedPushRecord {
        let record: CKRecord
        let modifiedAt: Date
    }

    struct PreparedPushRecords {
        let records: [PreparedPushRecord]
        let skippedItemIDs: [UUID]
    }

    nonisolated static func preparePushRecords(
        _ items: [ClipboardItem],
        in zoneID: CKRecordZone.ID,
        blobURL: (ClipboardItem) -> URL?
    ) -> PreparedPushRecords {
        var records: [PreparedPushRecord] = []
        var skippedItemIDs: [UUID] = []
        records.reserveCapacity(items.count)

        for item in items {
            let itemBlobURL = item.isDeleted ? nil : blobURL(item)
            guard let record = ClipboardCloudMapping.record(from: item, in: zoneID, blobURL: itemBlobURL) else {
                skippedItemIDs.append(item.id)
                continue
            }
            records.append(PreparedPushRecord(record: record, modifiedAt: item.modifiedAt))
        }

        return PreparedPushRecords(records: records, skippedItemIDs: skippedItemIDs)
    }

    nonisolated static func pushedWatermark(afterPushing records: [PreparedPushRecord]) -> Date? {
        records.map(\.modifiedAt).max()
    }

    private func existingBlobURL(for item: ClipboardItem) -> URL? {
        guard let reference = item.syncBlobReference,
              let url = store?.blobURL(for: reference),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func downloadBlobIfNeeded(
        from record: CKRecord,
        for item: ClipboardItem,
        into store: SyncableStore
    ) async throws -> SyncBlobReference? {
        guard !item.isDeleted, let blob = item.syncBlobReference else { return nil }
        // A blob is immutable for a given filename — editing a clip mints a new one — so if the
        // file is already on disk there is nothing to fetch. This skips re-reading the full (up to
        // 32 MB) CKAsset on every metadata-only edit (pin/tag), which re-surfaces the record in the
        // change feed with its asset attached.
        if let localURL = store.blobURL(for: blob), FileManager.default.fileExists(atPath: localURL.path) {
            return blob
        }
        guard let asset = record[ClipboardCloudMapping.Key.blob] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw CloudKitSyncError.missingBlobAsset(blob.filename)
        }
        let data = try await SyncBlobStorage.read(from: fileURL, maxBytes: blob.maximumBytes)
        try await store.writeBlob(data, reference: blob)
        return blob
    }

    private func deleteDownloadedBlobsNotReferenced(
        _ downloadedBlobs: Set<SyncBlobReference>,
        in store: SyncableStore
    ) {
        guard !downloadedBlobs.isEmpty else { return }
        let keptBlobs = Set(store.itemsForSync().compactMap(\.syncBlobReference))
        for blob in downloadedBlobs.subtracting(keptBlobs) {
            store.deleteBlob(blob)
        }
    }

    private func tombstone(_ id: UUID) -> ClipboardItem {
        let now = Date()
        return ClipboardItem(id: id, type: .text, timestamp: now, modifiedAt: now, deletedAt: now)
    }

    private var lastPushedModifiedAt: Date? {
        get { defaults.object(forKey: pushWatermarkKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: pushWatermarkKey)
            } else {
                defaults.removeObject(forKey: pushWatermarkKey)
            }
        }
    }

    private func persistToken(_ token: CKServerChangeToken?) {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            defaults.removeObject(forKey: tokenKey)
            return
        }
        defaults.set(data, forKey: tokenKey)
    }

    private static func loadToken(from defaults: UserDefaults, key: String) -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private extension ClipboardItem {
    var syncBlobReference: SyncBlobReference? {
        if let filename = imageFilename { return SyncBlobReference(filename: filename, kind: .image) }
        if let filename = textFilename { return SyncBlobReference(filename: filename, kind: .text) }
        return nil
    }
}
