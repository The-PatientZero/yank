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
    case partialRecordSaves(Int)
    case unpreparableLocalRecords(Int)
    case unrecoverableLocalRecords(Int)
    case backfillDidNotConverge(Int)
    case pushReceiptEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingBlobAsset(let filename):
            "Synced blob \(filename) is missing from CloudKit. Sync will retry."
        case .partialRecordFailures(let count):
            "CloudKit could not return \(count) changed record(s). Sync will retry."
        case .partialRecordSaves(let count):
            "CloudKit could not save \(count) record(s). Sync will retry."
        case .unpreparableLocalRecords(let count):
            "CloudKit could not prepare \(count) local record(s). Sync will retry before uploading."
        case .unrecoverableLocalRecords(let count):
            "Backfill stopped before upload because \(count) local record(s) are missing required blob data."
        case .backfillDidNotConverge(let count):
            "Backfill finished uploading, but \(count) local record(s) are still missing from CloudKit."
        case .pushReceiptEncodingFailed:
            "CloudKit push acknowledgements could not be saved. Sync will safely replay."
        }
    }
}

public struct CloudKitBackfillResult: Equatable, Sendable {
    public let localRecordCount: Int
    public let presentRecordCountBefore: Int
    public let missingRecordCountBefore: Int
    public let uploadedRecordCount: Int
    public let presentRecordCountAfter: Int
    public let remainingMissingRecordCount: Int

    public var converged: Bool {
        remainingMissingRecordCount == 0
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

struct CloudKitRecordSaveResult {
    var failedRecordNames: [String] = []
}

struct CloudKitRecordPresence {
    var presentRecordNames: Set<String> = []
    var missingRecordNames: Set<String> = []
}

/// The CloudKit operations `CloudKitSyncService` depends on, abstracted behind a seam (DIP)
/// so the orchestration — ensure zone/subscription → paginated pull → `ClipboardMerge` →
/// apply → receipt-driven push — is unit-tested against an in-memory fake instead of a live
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
    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence
    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult
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

    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence {
        let recordIDs = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let results = try await records(for: recordIDs, desiredKeys: [])
        var presence = CloudKitRecordPresence()
        var failedCount = 0

        for (recordID, result) in results {
            switch result {
            case .success:
                presence.presentRecordNames.insert(recordID.recordName)
            case .failure(let error) where Self.isUnknownItemError(error):
                presence.missingRecordNames.insert(recordID.recordName)
            case .failure:
                failedCount += 1
            }
        }
        let requestedRecordNames = Set(recordNames)
        let returnedRecordNames = presence.presentRecordNames.union(presence.missingRecordNames)
        failedCount += requestedRecordNames.subtracting(returnedRecordNames).count
        guard failedCount == 0 else {
            throw CloudKitSyncError.partialRecordFailures(failedCount)
        }
        return presence
    }

    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult {
        let results = try await modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
        var failedRecordNames = Set(results.saveResults.compactMap { recordID, result in
            if case .failure = result { return recordID.recordName }
            return nil
        })
        let requestedRecordNames = Set(records.map(\.recordID.recordName))
        let returnedRecordNames = Set(results.saveResults.keys.map(\.recordName))
        failedRecordNames.formUnion(requestedRecordNames.subtracting(returnedRecordNames))
        return CloudKitRecordSaveResult(failedRecordNames: failedRecordNames.sorted())
    }

    private static func isUnknownItemError(_ error: any Error) -> Bool {
        if let cloudKitError = error as? CKError {
            return cloudKitError.code == .unknownItem
        }
        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain
            && nsError.code == CKError.Code.unknownItem.rawValue
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
    private let pushReceiptsKey: String
    private let pushDebounceNanoseconds: UInt64
    private let beforeReceiptPersistence: (() throws -> Void)?
    private let afterReceiptInvalidationBeforeTokenPersistence: (() throws -> Void)?
    private weak var store: SyncableStore?
    private var changeToken: CKServerChangeToken?
    private var pushReceipts: [UUID: Date]?
    private var localChangeObserver: NSObjectProtocol?
    private var scheduledPush: Task<Void, Never>?
    private var activePush: (id: UUID, task: Task<Void, Error>)?
    private var lifecycleGeneration: UInt64 = 0
    private var isStopped = false

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
        defaults: UserDefaults = .standard,
        pushDebounceNanoseconds: UInt64 = 750_000_000,
        beforeReceiptPersistence: (() throws -> Void)? = nil,
        afterReceiptInvalidationBeforeTokenPersistence: (() throws -> Void)? = nil
    ) {
        self.database = database
        self.store = store
        self.defaults = defaults
        self.tokenKey = "cloudkit.changeToken.\(containerIdentifier)"
        self.pushWatermarkKey = "cloudkit.lastPushedModifiedAt.\(containerIdentifier)"
        self.pushReceiptsKey = "cloudkit.pushReceipts.\(containerIdentifier)"
        self.pushDebounceNanoseconds = pushDebounceNanoseconds
        self.beforeReceiptPersistence = beforeReceiptPersistence
        self.afterReceiptInvalidationBeforeTokenPersistence =
            afterReceiptInvalidationBeforeTokenPersistence
        self.changeToken = Self.loadToken(from: defaults, key: tokenKey)
        self.pushReceipts = Self.loadPushReceipts(from: defaults, key: pushReceiptsKey)
    }

    // `isolated deinit` runs cleanup on the main actor (the runtime hops if the last release lands
    // off-main), so it never traps the way `MainActor.assumeIsolated` would — important here, since
    // this service is captured by its own async start/push tasks and can be released off-main.
    isolated deinit {
        stop()
    }

    /// Permanently stops this service instance. Re-enabling sync creates a fresh service.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        lifecycleGeneration &+= 1
        scheduledPush?.cancel()
        scheduledPush = nil
        activePush?.task.cancel()
        activePush = nil
        if let localChangeObserver {
            NotificationCenter.default.removeObserver(localChangeObserver)
            self.localChangeObserver = nil
        }
    }

    /// Mark sync as unavailable on the store (e.g. no iCloud account, container not provisioned),
    /// without attempting a network round-trip.
    public func reportUnavailable(reason: SyncStatus.Reason) {
        guard !isStopped else { return }
        store?.markSyncUnavailable(reason: reason)
    }

    /// One-shot bring-up: ensure zone + push subscription, pull remote, push local.
    @discardableResult
    public func start() async -> CloudKitSyncStartResult {
        guard let generation = activeGeneration else {
            return .failed(message: Self.stoppedMessage)
        }
        do {
            try requireActive(generation)
            store?.markSyncStarted()
            try await ensureZone()
            try requireActive(generation)
            try await ensureSubscription()
            try requireActive(generation)
            try await pull(generation: generation)
            try requireActive(generation)
            try startObservingLocalChanges(generation: generation)
            try await pushLocal(generation: generation)
            try requireActive(generation)
            store?.markSyncSucceeded(at: Date())
            return .started
        } catch {
            let message = error.localizedDescription
            guard shouldReport(error, generation: generation) else {
                return .failed(message: message)
            }
            syncLog.error("start failed: \(message, privacy: .public)")
            store?.markSyncFailed(message)
            return .failed(message: message)
        }
    }

    /// One-time UUID-preserving recovery for historical local records that CloudKit never
    /// accepted. Presence checks fetch record metadata only, existing records are never
    /// updated or deleted, and ordinary incremental push receipts are left untouched.
    public func backfillMissingLocalRecords(dryRun: Bool = false) async throws -> CloudKitBackfillResult {
        guard let generation = activeGeneration else { throw CancellationError() }
        try requireActive(generation)
        guard let store else {
            return CloudKitBackfillResult(
                localRecordCount: 0,
                presentRecordCountBefore: 0,
                missingRecordCountBefore: 0,
                uploadedRecordCount: 0,
                presentRecordCountAfter: 0,
                remainingMissingRecordCount: 0
            )
        }

        let localItems = store.itemsForSync()
        let localRecordNames = localItems.map { $0.id.uuidString }
        let before = try await fetchRecordPresence(for: localRecordNames, generation: generation)
        try requireActive(generation)
        let missingItems = localItems.filter {
            before.missingRecordNames.contains($0.id.uuidString)
        }
        let prepared = Self.preparePushRecords(missingItems, in: zoneID) { item in
            item.isDeleted ? nil : existingBlobURL(for: item)
        }
        guard prepared.skippedItemIDs.isEmpty else {
            throw CloudKitSyncError.unrecoverableLocalRecords(prepared.skippedItemIDs.count)
        }

        if !dryRun {
            try requireActive(generation)
            try await savePreparedRecords(prepared.records, generation: generation)
        }

        let after = dryRun
            ? before
            : try await fetchRecordPresence(for: localRecordNames, generation: generation)
        try requireActive(generation)
        if !dryRun, !after.missingRecordNames.isEmpty {
            throw CloudKitSyncError.backfillDidNotConverge(after.missingRecordNames.count)
        }

        return CloudKitBackfillResult(
            localRecordCount: localItems.count,
            presentRecordCountBefore: before.presentRecordNames.count,
            missingRecordCountBefore: before.missingRecordNames.count,
            uploadedRecordCount: dryRun ? 0 : prepared.records.count,
            presentRecordCountAfter: after.presentRecordNames.count,
            remainingMissingRecordCount: after.missingRecordNames.count
        )
    }

    private func startObservingLocalChanges(generation: UInt64) throws {
        try requireActive(generation)
        guard localChangeObserver == nil else { return }
        localChangeObserver = NotificationCenter.default.addObserver(
            forName: .yankLocalStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.requireActive(generation)
                    try self.schedulePush(generation: generation)
                } catch {
                    // A queued notification from a stopped generation is intentionally ignored.
                }
            }
        }
    }

    /// Called from the silent push handler to fold in remote changes.
    @discardableResult
    public func handleRemoteChange() async -> Bool {
        guard let generation = activeGeneration else { return false }
        do {
            try requireActive(generation)
            try await pull(generation: generation)
            try requireActive(generation)
            // Receipt comparison makes this a no-op for a clean pull. Always reconsidering
            // local state is what lets an ordinary remote change repair a missing CKAsset.
            try await pushLocal(generation: generation)
            try requireActive(generation)
            store?.markSyncSucceeded(at: Date())
            return true
        } catch {
            let message = error.localizedDescription
            guard shouldReport(error, generation: generation) else { return false }
            syncLog.error("remote pull failed: \(message, privacy: .public)")
            store?.markSyncFailed(message)
            return false
        }
    }

    private func schedulePush(generation: UInt64) throws {
        try requireActive(generation)
        scheduledPush?.cancel()
        let debounceNanoseconds = pushDebounceNanoseconds
        scheduledPush = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                guard let self else { return }
                try self.requireActive(generation)
                try await self.pushLocal(generation: generation)
                try self.requireActive(generation)
                self.store?.markSyncSucceeded(at: Date())
            } catch {
                guard let self, self.shouldReport(error, generation: generation) else { return }
                let message = error.localizedDescription
                syncLog.error("local push failed: \(message, privacy: .public)")
                self.store?.markSyncFailed(message)
            }
        }
    }

    private func ensureZone() async throws {
        try await database.ensureZone(zoneID)
    }

    private func ensureSubscription() async throws {
        try await database.ensureSubscription(id: subscriptionID)
    }

    /// Returns true when an expired token was recovered and callers should reconsider local state.
    @discardableResult
    private func pull(generation: UInt64) async throws -> Bool {
        do {
            try await pullUsingCurrentToken(generation: generation)
            try requireActive(generation)
            return false
        } catch {
            try requireActive(generation)
            guard Self.isExpiredChangeTokenError(error) else { throw error }
            syncLog.info("CloudKit change token expired; retrying from the beginning.")
            try invalidateAllPushReceipts(generation: generation)
            try afterReceiptInvalidationBeforeTokenPersistence?()
            try requireActive(generation)
            try persistToken(nil, generation: generation)
            changeToken = nil
            try await pullUsingCurrentToken(generation: generation)
            try requireActive(generation)
            return true
        }
    }

    private func pullUsingCurrentToken(generation: UInt64) async throws {
        try requireActive(generation)
        guard let store else { return }
        var remote: [ClipboardItem] = []
        var downloadedBlobs: Set<SyncBlobReference> = []
        var receiptInvalidationItemIDs: Set<UUID> = []
        var token = changeToken
        var moreComing = true
        do {
            while moreComing {
                let changes = try await database.fetchZoneChanges(zoneID, since: token)
                try requireActive(generation)
                guard changes.failedRecordNames.isEmpty else {
                    throw CloudKitSyncError.partialRecordFailures(changes.failedRecordNames.count)
                }
                for record in changes.changedRecords {
                    try requireActive(generation)
                    guard let resolved = try await resolveRemoteItem(
                        from: record,
                        into: store,
                        generation: generation
                    ) else { continue }
                    try requireActive(generation)
                    if let blob = resolved.blob { downloadedBlobs.insert(blob) }
                    if resolved.requiresLocalRepush {
                        receiptInvalidationItemIDs.insert(resolved.item.id)
                    }
                    remote.append(resolved.item)
                }
                for recordName in changes.deletedRecordNames {
                    if let id = UUID(uuidString: recordName) {
                        remote.append(tombstone(id))
                    }
                }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            try requireActive(generation)
            let local = store.itemsForSync()
            let reconciled = ClipboardMerge.reconcile(local, remote)
            try requireActive(generation)
            try store.applyReconciledDurably(reconciled)
            try requireActive(generation)
            deleteDownloadedBlobsNotReferenced(downloadedBlobs, in: store)
            if !receiptInvalidationItemIDs.isEmpty {
                // A push that started before this pull may still commit an older receipt
                // snapshot. Let it finish, then make repair invalidation the last durable
                // receipt transition before acknowledging the remote change token.
                try await awaitActivePushCompletion(generation: generation)
                try requireActive(generation)
                try invalidatePushReceipts(
                    for: receiptInvalidationItemIDs,
                    generation: generation
                )
                try afterReceiptInvalidationBeforeTokenPersistence?()
                try requireActive(generation)
            }
            try persistToken(token, generation: generation)
            changeToken = token
        } catch {
            if canMutate(generation) {
                deleteDownloadedBlobsNotReferenced(downloadedBlobs, in: store)
            }
            throw error
        }
    }

    private func resolveRemoteItem(
        from record: CKRecord,
        into store: SyncableStore,
        generation: UInt64
    ) async throws -> (item: ClipboardItem, blob: SyncBlobReference?, requiresLocalRepush: Bool)? {
        try requireActive(generation)
        guard let item = ClipboardCloudMapping.item(from: record) else { return nil }
        switch try await resolveRemoteBlob(
            from: record,
            for: item,
            into: store,
            generation: generation
        ) {
        case .notRequired:
            return (item, nil, false)
        case .available(let blob, let requiresLocalRepush):
            return (item, blob, requiresLocalRepush)
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

    private func pushLocal(generation: UInt64) async throws {
        try requireActive(generation)
        if activePush != nil {
            try await awaitActivePushCompletion(generation: generation)
            try requireActive(generation)
            try await pushLocal(generation: generation)
            return
        }

        let pushID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try self.requireActive(generation)
            try await self.performPushLocal(generation: generation)
        }
        try requireActive(generation)
        activePush = (pushID, task)
        do {
            try await task.value
            try requireActive(generation)
            if activePush?.id == pushID {
                activePush = nil
            }
        } catch {
            if activePush?.id == pushID {
                activePush = nil
            }
            throw error
        }
    }

    private func awaitActivePushCompletion(generation: UInt64) async throws {
        try requireActive(generation)
        while let activePush {
            do {
                try await activePush.task.value
                try requireActive(generation)
                if self.activePush?.id == activePush.id {
                    self.activePush = nil
                }
            } catch {
                if self.activePush?.id == activePush.id {
                    self.activePush = nil
                }
                throw error
            }
        }
    }

    private func performPushLocal(generation: UInt64) async throws {
        try requireActive(generation)
        guard let store else { return }
        let local = store.itemsForSync()
        let isReceiptMigration = pushReceipts == nil

        let existingReceipts = pushReceipts ?? [:]
        let itemsToPush = Self.itemsNeedingPush(local, receipts: pushReceipts)
        let currentItemIDs = Set(local.map(\.id))
        var nextReceipts = existingReceipts.filter { currentItemIDs.contains($0.key) }
        guard !itemsToPush.isEmpty else {
            if isReceiptMigration || nextReceipts != existingReceipts {
                try persistPushReceipts(nextReceipts, generation: generation)
            }
            return
        }

        try requireActive(generation)
        let prepared = Self.preparePushRecords(itemsToPush, in: zoneID) { item in
            item.isDeleted ? nil : existingBlobURL(for: item)
        }
        for skippedID in prepared.skippedItemIDs {
            syncLog.error("skipping clip with invalid sync blob metadata: \(skippedID.uuidString, privacy: .public)")
        }
        guard prepared.skippedItemIDs.isEmpty else {
            throw CloudKitSyncError.unpreparableLocalRecords(prepared.skippedItemIDs.count)
        }
        try requireActive(generation)
        try await savePreparedRecords(prepared.records, generation: generation)
        try requireActive(generation)
        let canonicalItemIDsAfterSave = Set(store.itemsForSync().map(\.id))
        nextReceipts = existingReceipts.filter { canonicalItemIDsAfterSave.contains($0.key) }
        for pushed in prepared.records where canonicalItemIDsAfterSave.contains(pushed.itemID) {
            nextReceipts[pushed.itemID] = pushed.modifiedAt
        }
        try persistPushReceipts(nextReceipts, generation: generation)
    }

    private func fetchRecordPresence(
        for recordNames: [String],
        generation: UInt64
    ) async throws -> CloudKitRecordPresence {
        var combined = CloudKitRecordPresence()
        for batch in recordNames.chunked(into: 100) {
            let presence = try await database.fetchRecordPresence(for: batch, in: zoneID)
            try requireActive(generation)
            combined.presentRecordNames.formUnion(presence.presentRecordNames)
            combined.missingRecordNames.formUnion(presence.missingRecordNames)
        }
        return combined
    }

    private func savePreparedRecords(
        _ records: [PreparedPushRecord],
        generation: UInt64
    ) async throws {
        for batch in records.map(\.record).chunked(into: 100) {
            let result = try await database.saveRecords(batch)
            try requireActive(generation)
            guard result.failedRecordNames.isEmpty else {
                throw CloudKitSyncError.partialRecordSaves(result.failedRecordNames.count)
            }
        }
    }

    nonisolated static func itemsNeedingPush(
        _ items: [ClipboardItem],
        receipts: [UUID: Date]?
    ) -> [ClipboardItem] {
        guard let receipts else { return items }
        return items.filter { receipts[$0.id] != $0.modifiedAt }
    }

    struct PreparedPushRecord {
        let itemID: UUID
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
            if !item.isDeleted, item.syncBlobReference != nil, itemBlobURL == nil {
                skippedItemIDs.append(item.id)
                continue
            }
            guard let record = ClipboardCloudMapping.record(from: item, in: zoneID, blobURL: itemBlobURL) else {
                skippedItemIDs.append(item.id)
                continue
            }
            records.append(PreparedPushRecord(itemID: item.id, record: record, modifiedAt: item.modifiedAt))
        }

        return PreparedPushRecords(records: records, skippedItemIDs: skippedItemIDs)
    }

    private func existingBlobURL(for item: ClipboardItem) -> URL? {
        guard let reference = item.syncBlobReference,
              let url = store?.blobURL(for: reference),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private enum RemoteBlobResolution {
        case notRequired
        case available(SyncBlobReference, requiresLocalRepush: Bool)
    }

    private func resolveRemoteBlob(
        from record: CKRecord,
        for item: ClipboardItem,
        into store: SyncableStore,
        generation: UInt64
    ) async throws -> RemoteBlobResolution {
        try requireActive(generation)
        guard !item.isDeleted, let blob = item.syncBlobReference else { return .notRequired }
        let assetURL = (record[ClipboardCloudMapping.Key.blob] as? CKAsset)?.fileURL
        // A blob is immutable for a given filename — editing a clip mints a new one — so if the
        // file is already on disk there is nothing to fetch. This skips re-reading the full (up to
        // 32 MB) CKAsset on every metadata-only edit (pin/tag), which re-surfaces the record in the
        // change feed with its asset attached.
        if let localURL = store.blobURL(for: blob), FileManager.default.fileExists(atPath: localURL.path) {
            let requiresLocalRepush = assetURL == nil
            if requiresLocalRepush {
                syncLog.error(
                    "synced clip \(item.id.uuidString, privacy: .public) is missing its asset; scheduling repair"
                )
            }
            return .available(blob, requiresLocalRepush: requiresLocalRepush)
        }
        guard let assetURL else {
            syncLog.error(
                "cannot apply synced clip \(item.id.uuidString, privacy: .public) because its blob asset is missing"
            )
            throw CloudKitSyncError.missingBlobAsset(blob.filename)
        }
        let data = try await SyncBlobStorage.read(from: assetURL, maxBytes: blob.maximumBytes)
        try requireActive(generation)
        try await writeRemoteBlobStaged(
            data,
            destination: blob,
            into: store,
            generation: generation
        )
        return .available(blob, requiresLocalRepush: false)
    }

    /// Writes a downloaded asset under a throwaway valid blob name, then promotes it only while
    /// this service generation is still active. The store's existing public API stays compatible,
    /// and cancellation-ignoring file I/O can leave at most a staging file that this scope removes.
    private func writeRemoteBlobStaged(
        _ data: Data,
        destination: SyncBlobReference,
        into store: SyncableStore,
        generation: UInt64
    ) async throws {
        guard let staging = SyncBlobReference(
            filename: "\(UUID().uuidString).\(destination.kind.allowedExtension)",
            kind: destination.kind
        ) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }

        defer { store.deleteBlob(staging) }
        try await store.writeBlob(data, reference: staging)
        try requireActive(generation)

        guard let stagingURL = store.blobURL(for: staging),
              let destinationURL = store.blobURL(for: destination) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
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

    private func persistPushReceipts(
        _ receipts: [UUID: Date],
        generation: UInt64
    ) throws {
        try requireActive(generation)
        try beforeReceiptPersistence?()
        try requireActive(generation)
        guard let data = try? CloudKitPushReceiptCodec.encode(receipts) else {
            throw CloudKitSyncError.pushReceiptEncodingFailed
        }
        try requireActive(generation)
        defaults.set(data, forKey: pushReceiptsKey)
        pushReceipts = receipts
        // Receipt state is authoritative in this build. Removing the legacy checkpoint only after
        // the replacement is durable makes every migration failure retryable by a full replay.
        defaults.removeObject(forKey: pushWatermarkKey)
    }

    private func invalidatePushReceipts(
        for itemIDs: Set<UUID>,
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard var receipts = pushReceipts else {
            // A missing envelope already means every canonical item must be replayed.
            return
        }
        let previousReceipts = receipts
        for itemID in itemIDs {
            receipts.removeValue(forKey: itemID)
        }
        guard receipts != previousReceipts else { return }
        try persistPushReceipts(receipts, generation: generation)
    }

    private func invalidateAllPushReceipts(generation: UInt64) throws {
        try requireActive(generation)
        defaults.removeObject(forKey: pushReceiptsKey)
        pushReceipts = nil
    }

    private static func loadPushReceipts(
        from defaults: UserDefaults,
        key: String
    ) -> [UUID: Date]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? CloudKitPushReceiptCodec.decode(data)
    }

    private func persistToken(
        _ token: CKServerChangeToken?,
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            defaults.removeObject(forKey: tokenKey)
            return
        }
        defaults.set(data, forKey: tokenKey)
    }

    private var activeGeneration: UInt64? {
        isStopped ? nil : lifecycleGeneration
    }

    private func requireActive(_ generation: UInt64) throws {
        guard canMutate(generation) else { throw CancellationError() }
    }

    private func canMutate(_ generation: UInt64) -> Bool {
        !isStopped && lifecycleGeneration == generation && !Task.isCancelled
    }

    private func shouldReport(_ error: any Error, generation: UInt64) -> Bool {
        canMutate(generation) && !(error is CancellationError)
    }

    private static let stoppedMessage = "CloudKit sync stopped."

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
