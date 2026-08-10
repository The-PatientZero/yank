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
    case unrecoverableLocalRecords(Int)
    case backfillDidNotConverge(Int)
    case pushReceiptEncodingFailed
    case pullQuarantineEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingBlobAsset(let filename):
            "Synced blob \(filename) is missing from CloudKit. Sync will retry."
        case .partialRecordFailures(let count):
            "CloudKit could not return \(count) changed record(s). Sync will retry."
        case .partialRecordSaves(let count):
            "CloudKit could not save \(count) record(s). Sync will retry."
        case .unrecoverableLocalRecords(let count):
            "Backfill stopped before upload because \(count) local record(s) are missing required blob data."
        case .backfillDidNotConverge(let count):
            "Backfill finished uploading, but \(count) local record(s) are still missing from CloudKit."
        case .pushReceiptEncodingFailed:
            "CloudKit push acknowledgements could not be saved. Sync will safely replay."
        case .pullQuarantineEncodingFailed:
            "Skipped CloudKit records could not be recorded. Sync will safely replay."
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
    /// Records the server acknowledged but could not hand over. The error is carried so the pull
    /// can tell a permanently gone record (skip it) from a transient failure (hold the token).
    var failedRecords: [CloudKitRecordFailure] = []
    var changeToken: CKServerChangeToken?
    var moreComing: Bool
}

struct CloudKitRecordFailure {
    let recordName: String
    let error: any Error
}

/// Result of re-fetching specific records by ID. Records CloudKit no longer has are reported
/// separately from transient failures, which are simply absent and retried by a later pull.
struct CloudKitFetchedRecords {
    var records: [CKRecord] = []
    var permanentlyMissingRecordNames: Set<String> = []
}

struct CloudKitRecordSaveResult {
    var failedRecordNames: [String] = []
}

/// Outcome of a conditional (`.ifServerRecordUnchanged`) save. `conflict` means the server's
/// copy moved on since the record being saved was fetched — the caller has to re-read it and
/// decide who wins rather than blindly overwriting.
enum CloudKitConditionalSaveOutcome: Equatable {
    case saved
    case conflict
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
    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords
    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult
    /// Save one record only while the server's copy still matches the change tag it carries.
    /// Separate from `saveRecords` because the clip path deliberately uses `.changedKeys`
    /// last-writer-wins, while the singleton settings record must never clobber a newer remote.
    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome
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
        var failedRecords: [CloudKitRecordFailure] = []
        changedRecords.reserveCapacity(changes.modificationResultsByID.count)
        failedRecords.reserveCapacity(changes.modificationResultsByID.count)
        for (recordID, result) in changes.modificationResultsByID {
            switch result {
            case .success(let modification):
                changedRecords.append(modification.record)
            case .failure(let error):
                failedRecords.append(
                    CloudKitRecordFailure(recordName: recordID.recordName, error: error)
                )
            }
        }
        return CloudKitZoneChanges(
            changedRecords: changedRecords,
            deletedRecordNames: changes.deletions.map { $0.recordID.recordName },
            failedRecords: failedRecords.sorted { $0.recordName < $1.recordName },
            changeToken: changes.changeToken,
            moreComing: changes.moreComing
        )
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords {
        let recordIDs = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let results = try await records(for: recordIDs)
        var fetched = CloudKitFetchedRecords()
        fetched.records.reserveCapacity(results.count)
        for (recordID, result) in results {
            switch result {
            case .success(let record):
                fetched.records.append(record)
            case .failure(let error) where Self.isUnknownItemError(error):
                fetched.permanentlyMissingRecordNames.insert(recordID.recordName)
            case .failure:
                // Transient: the record stays quarantined and a later pull re-attempts it.
                continue
            }
        }
        return fetched
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

    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        do {
            let results = try await modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged
            )
            guard let result = results.saveResults[record.recordID] else {
                throw CloudKitSyncError.partialRecordSaves(1)
            }
            switch result {
            case .success:
                return .saved
            case .failure(let error):
                guard Self.isServerRecordChangedError(error) else { throw error }
                return .conflict
            }
        } catch let error where Self.isServerRecordChangedError(error) {
            // A single-record modify can surface the conflict as a thrown partial failure
            // instead of a per-record result, depending on how the operation is rejected.
            return .conflict
        }
    }

    private static func isUnknownItemError(_ error: any Error) -> Bool {
        if let cloudKitError = error as? CKError {
            return cloudKitError.code == .unknownItem
        }
        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain
            && nsError.code == CKError.Code.unknownItem.rawValue
    }

    private static func isServerRecordChangedError(_ error: any Error) -> Bool {
        guard let cloudKitError = error as? CKError else {
            let nsError = error as NSError
            return nsError.domain == CKError.errorDomain
                && nsError.code == CKError.Code.serverRecordChanged.rawValue
        }
        if cloudKitError.code == .serverRecordChanged { return true }
        guard cloudKitError.code == .partialFailure,
              let itemErrors = cloudKitError.partialErrorsByItemID else { return false }
        return itemErrors.values.contains { isServerRecordChangedError($0) }
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
    private let pullQuarantineKey: String
    private let pushDebounceNanoseconds: UInt64
    private let pushRetryDelaysNanoseconds: [UInt64]
    private let beforeReceiptPersistence: (() throws -> Void)?
    private let afterReceiptInvalidationBeforeTokenPersistence: (() throws -> Void)?
    private weak var store: SyncableStore?
    /// Weak for the same reason as `store`: the composition root owns the settings bridge and
    /// outlives the service, and a strong edge here would keep the app's settings graph alive
    /// past `stop()`.
    private weak var settingsStore: (any SyncedSettingsStore)?
    private var changeToken: CKServerChangeToken?
    private var pushReceipts: [UUID: Date]?
    private var pullQuarantine: [String: CloudKitPullQuarantineEntry]
    /// Whether the settings record is worth a round trip on the next push. Purely an
    /// optimisation — the fetch-first reconcile decides by stamp, never by this flag — so a
    /// change made while sync was down is still published by the next `start()`.
    private var settingsReconciliationPending = false
    private var localChangeObserver: NSObjectProtocol?
    private var settingsChangeObserver: NSObjectProtocol?
    private var scheduledPush: Task<Void, Never>?
    private var pushRetry: Task<Void, Never>?
    private var pushRetryAttempt = 0
    private var activePush: (id: UUID, task: Task<Void, Error>)?
    private var lifecycleGeneration: UInt64 = 0
    private var isStopped = false

    /// Live entry point: binds to the container's private database. `CKContainer(identifier:)`
    /// hard-traps on a binary not provisioned for the container, so callers must gate on
    /// provisioning before constructing the service (see `AppDelegate`).
    public convenience init(
        containerIdentifier: String,
        store: SyncableStore,
        settingsStore: (any SyncedSettingsStore)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            containerIdentifier: containerIdentifier,
            store: store,
            database: CKContainer(identifier: containerIdentifier).privateCloudDatabase,
            settingsStore: settingsStore,
            defaults: defaults
        )
    }

    /// Seam-injecting initializer — tests pass an in-memory `CloudKitDatabase` fake.
    init(
        containerIdentifier: String,
        store: SyncableStore,
        database: any CloudKitDatabase,
        settingsStore: (any SyncedSettingsStore)? = nil,
        defaults: UserDefaults = .standard,
        pushDebounceNanoseconds: UInt64 = 750_000_000,
        pushRetryDelaysNanoseconds: [UInt64] = CloudKitSyncService.defaultPushRetryDelaysNanoseconds,
        beforeReceiptPersistence: (() throws -> Void)? = nil,
        afterReceiptInvalidationBeforeTokenPersistence: (() throws -> Void)? = nil
    ) {
        self.database = database
        self.store = store
        self.settingsStore = settingsStore
        self.defaults = defaults
        self.tokenKey = "cloudkit.changeToken.\(containerIdentifier)"
        self.pushWatermarkKey = "cloudkit.lastPushedModifiedAt.\(containerIdentifier)"
        self.pushReceiptsKey = "cloudkit.pushReceipts.\(containerIdentifier)"
        self.pullQuarantineKey = "cloudkit.pullQuarantine.\(containerIdentifier)"
        self.pushDebounceNanoseconds = pushDebounceNanoseconds
        self.pushRetryDelaysNanoseconds = pushRetryDelaysNanoseconds
        self.beforeReceiptPersistence = beforeReceiptPersistence
        self.afterReceiptInvalidationBeforeTokenPersistence =
            afterReceiptInvalidationBeforeTokenPersistence
        self.changeToken = Self.loadToken(from: defaults, key: tokenKey)
        self.pushReceipts = Self.loadPushReceipts(from: defaults, key: pushReceiptsKey)
        self.pullQuarantine = Self.loadPullQuarantine(from: defaults, key: pullQuarantineKey)
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
        cancelPushRetry()
        pushRetryAttempt = 0
        activePush?.task.cancel()
        activePush = nil
        if let localChangeObserver {
            NotificationCenter.default.removeObserver(localChangeObserver)
            self.localChangeObserver = nil
        }
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
            self.settingsChangeObserver = nil
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
            // Bring-up always reconciles the settings record, which is what recovers a record
            // an earlier build could not read and one this device never managed to publish.
            settingsReconciliationPending = true
            try await pull(generation: generation)
            try requireActive(generation)
            try startObservingLocalChanges(generation: generation)
            try startObservingSettingsChanges(generation: generation)
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

    /// Observes local settings choices directly, exactly as the clip path observes local store
    /// changes — so no composition root has to relay them. Only a *choice* posts this; an
    /// adopted value stays silent and cannot bounce back at the device it came from.
    private func startObservingSettingsChanges(generation: UInt64) throws {
        try requireActive(generation)
        guard settingsChangeObserver == nil else { return }
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .yankSyncedSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.requireActive(generation)
                    self.settingsReconciliationPending = true
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
        // A fresh trigger supersedes any backoff still waiting from an earlier failure.
        cancelPushRetry()
        pushRetryAttempt = 0
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
                self.schedulePushRetry(after: error, generation: generation)
            }
        }
    }

    /// Advances the bounded backoff chain after a failed push. Without it a transient CloudKit
    /// failure parks the pending records until the next local change or app launch.
    private func schedulePushRetry(after error: any Error, generation: UInt64) {
        guard canMutate(generation) else { return }
        guard pushRetryAttempt < pushRetryDelaysNanoseconds.count else {
            syncLog.error("local push retries exhausted; waiting for the next sync trigger")
            return
        }
        let delayNanoseconds = Self.pushRetryDelayNanoseconds(
            for: error,
            fallback: pushRetryDelaysNanoseconds[pushRetryAttempt]
        )
        pushRetryAttempt += 1
        let attempt = pushRetryAttempt
        pushRetry = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                guard let self else { return }
                // This attempt is no longer pending, so a failure can arm the next one.
                self.pushRetry = nil
                try self.requireActive(generation)
                syncLog.info("retrying local push (attempt \(attempt, privacy: .public))")
                try await self.pushLocal(generation: generation)
                try self.requireActive(generation)
                self.pushRetryAttempt = 0
                self.store?.markSyncSucceeded(at: Date())
            } catch {
                guard let self, self.shouldReport(error, generation: generation) else { return }
                let message = error.localizedDescription
                syncLog.error("local push retry failed: \(message, privacy: .public)")
                self.store?.markSyncFailed(message)
                self.schedulePushRetry(after: error, generation: generation)
            }
        }
    }

    private func cancelPushRetry() {
        pushRetry?.cancel()
        pushRetry = nil
    }

    /// CloudKit's own `retryAfterSeconds` hint wins over the local backoff step when present,
    /// clamped so a nonsensical server value cannot park the chain (or trap the conversion).
    nonisolated static func pushRetryDelayNanoseconds(
        for error: any Error,
        fallback: UInt64
    ) -> UInt64 {
        guard let seconds = retryAfterSeconds(from: error), seconds.isFinite, seconds > 0 else {
            return fallback
        }
        let requested = seconds * 1_000_000_000
        guard requested < Double(maximumPushRetryDelayNanoseconds) else {
            return maximumPushRetryDelayNanoseconds
        }
        return UInt64(requested)
    }

    private nonisolated static func retryAfterSeconds(from error: any Error) -> Double? {
        if let cloudKitError = error as? CKError {
            return cloudKitError.retryAfterSeconds
        }
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return nil }
        return nsError.userInfo[CKErrorRetryAfterKey] as? Double
    }

    nonisolated static let defaultPushRetryDelaysNanoseconds: [UInt64] = [
        5_000_000_000,
        30_000_000_000,
        120_000_000_000
    ]

    private nonisolated static let maximumPushRetryDelayNanoseconds: UInt64 = 3_600_000_000_000

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
        var accumulation = PullAccumulation()
        var quarantine = QuarantineState(entries: pullQuarantine)
        var token = changeToken
        var moreComing = true
        do {
            // Re-attempt earlier skipped records first, so a recovered one lands in the same
            // durable apply as this pull's page set.
            try await recoverQuarantinedRecords(
                into: store,
                accumulation: &accumulation,
                quarantine: &quarantine,
                generation: generation
            )
            while moreComing {
                let changes = try await database.fetchZoneChanges(zoneID, since: token)
                try requireActive(generation)
                try quarantinePermanentServerFailures(
                    changes.failedRecords,
                    quarantine: &quarantine
                )
                for record in changes.changedRecords {
                    try requireActive(generation)
                    try await accumulateRemoteRecord(
                        record,
                        into: store,
                        accumulation: &accumulation,
                        quarantine: &quarantine,
                        generation: generation
                    )
                }
                for recordName in changes.deletedRecordNames {
                    // A record deleted server-side has nothing left to recover.
                    quarantine.clear(recordName)
                    if let id = UUID(uuidString: recordName) {
                        accumulation.remote.append(tombstone(id))
                    }
                }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            try requireActive(generation)
            let local = store.itemsForSync()
            for bypassed in accumulation.bypassedMissingAssets {
                guard Self.localTombstoneDominates(
                    bypassed.item,
                    in: local
                ) else {
                    throw CloudKitSyncError.missingBlobAsset(bypassed.blob.filename)
                }
            }
            let reconciled = ClipboardMerge.reconcile(local, accumulation.remote)
            try requireActive(generation)
            try store.applyReconciledDurably(reconciled)
            try requireActive(generation)
            deleteDownloadedBlobsNotReferenced(accumulation.downloadedBlobs, in: store)
            // After the clips land, so a tightened remote limit trims the merged set rather than
            // the pre-merge one. Adoption is idempotent against the local stamp, so replaying
            // this pull after a later failure re-decides the same way.
            if let remoteSettings = accumulation.remoteSettings {
                applySettingsFromChangeFeed(remoteSettings)
                try requireActive(generation)
            }
            if !accumulation.receiptInvalidationItemIDs.isEmpty {
                // A push that started before this pull may still commit an older receipt
                // snapshot. Let it finish, then make repair invalidation the last durable
                // receipt transition before acknowledging the remote change token.
                try await awaitActivePushCompletion(generation: generation)
                try requireActive(generation)
                try invalidatePushReceipts(
                    for: accumulation.receiptInvalidationItemIDs,
                    generation: generation
                )
                try afterReceiptInvalidationBeforeTokenPersistence?()
                try requireActive(generation)
            }
            // Durable before the token: a crash here replays the page instead of losing the
            // record that was skipped.
            if quarantine.didChange {
                try persistPullQuarantine(quarantine.entries, generation: generation)
            }
            try persistToken(token, generation: generation)
            changeToken = token
        } catch {
            if canMutate(generation) {
                deleteDownloadedBlobsNotReferenced(accumulation.downloadedBlobs, in: store)
            }
            throw error
        }
    }

    /// Everything one pull collects before it becomes a single durable apply.
    private struct PullAccumulation {
        var remote: [ClipboardItem] = []
        var downloadedBlobs: Set<SyncBlobReference> = []
        var bypassedMissingAssets: [(item: ClipboardItem, blob: SyncBlobReference)] = []
        var receiptInvalidationItemIDs: Set<UUID> = []
        /// The settings record seen in this pull, if any. Last one wins within a pull — the
        /// record is a singleton, so a later page can only be a newer copy of the same thing.
        var remoteSettings: SyncedSettings?
    }

    /// In-flight quarantine list for one pull. Only persisted once the pull's records are durable.
    private struct QuarantineState {
        var entries: [String: CloudKitPullQuarantineEntry]
        var didChange = false

        mutating func clear(_ recordName: String) {
            guard entries.removeValue(forKey: recordName) != nil else { return }
            didChange = true
        }

        mutating func record(_ recordName: String, reason: String) {
            let existingAttemptCount = entries[recordName]?.attemptCount
            guard existingAttemptCount != nil
                    || entries.count < CloudKitPullQuarantineCodec.maximumEntryCount else {
                syncLog.error(
                    "quarantine is full; skipped record \(recordName, privacy: .public) is untracked: \(reason, privacy: .public)"
                )
                return
            }
            let attemptCount = (existingAttemptCount ?? 0) + 1
            entries[recordName] = CloudKitPullQuarantineEntry(
                reason: CloudKitPullQuarantineCodec.truncatedReason(reason),
                attemptCount: attemptCount
            )
            didChange = true
            if attemptCount >= CloudKitSyncService.maximumQuarantineAttempts {
                syncLog.error(
                    "record \(recordName, privacy: .public) failed \(attemptCount, privacy: .public) resolution attempts; leaving it quarantined for recovery: \(reason, privacy: .public)"
                )
            } else {
                syncLog.error(
                    "quarantining record \(recordName, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
    }

    /// Folds one remote record into the pending pull. A record that can never resolve is
    /// quarantined and skipped instead of holding the change token — and every other record —
    /// hostage forever.
    private func accumulateRemoteRecord(
        _ record: CKRecord,
        into store: SyncableStore,
        accumulation: inout PullAccumulation,
        quarantine: inout QuarantineState,
        generation: UInt64
    ) async throws {
        try requireActive(generation)
        let recordName = record.recordID.recordName
        // Branch on the record type before any clip mapping: the settings record is not a clip,
        // so it must never reach `ClipboardCloudMapping` (which would read it as unmappable) or
        // the quarantine. This is the single choke point for remote records — the page loop and
        // the quarantine-recovery re-fetch both come through here.
        if record.recordType == SyncedSettingsCloudMapping.recordType {
            if let settings = SyncedSettingsCloudMapping.settings(from: record) {
                accumulation.remoteSettings = settings
            } else {
                // Not an error, and nothing to hold the change token for: a value this build
                // cannot read now will not become readable by replaying the same page. The
                // fetch-first reconcile on the next launch is what picks it up after an upgrade.
                syncLog.info(
                    "settings record \(recordName, privacy: .public) is not readable by this build; leaving it to the next reconcile"
                )
            }
            // A 1.0.5 client quarantined this record as an unmappable clip. Now that the type is
            // understood, drop that entry instead of leaving it to burn recovery attempts.
            quarantine.clear(recordName)
            return
        }
        let resolved: RemoteItemResolution?
        do {
            resolved = try await resolveRemoteItem(
                from: record,
                into: store,
                generation: generation
            )
        } catch let error where Self.isPermanentRecordResolutionFailure(error) {
            quarantine.record(recordName, reason: error.localizedDescription)
            return
        }
        try requireActive(generation)
        guard let resolved else {
            quarantine.record(recordName, reason: Self.unmappableRecordReason)
            return
        }
        switch resolved {
        case .available(let item, let blob, let requiresLocalRepush):
            if let blob { accumulation.downloadedBlobs.insert(blob) }
            if requiresLocalRepush {
                accumulation.receiptInvalidationItemIDs.insert(item.id)
            }
            accumulation.remote.append(item)
        case .missingAssetShadowedByLocalTombstone(let item, let blob):
            accumulation.bypassedMissingAssets.append((item, blob))
            accumulation.receiptInvalidationItemIDs.insert(item.id)
            accumulation.remote.append(item)
        }
        quarantine.clear(recordName)
    }

    /// Re-fetches a bounded batch of quarantined records. Recovery is best effort: a transport
    /// failure here must not stop the healthy change feed, and it does not spend a retry.
    private func recoverQuarantinedRecords(
        into store: SyncableStore,
        accumulation: inout PullAccumulation,
        quarantine: inout QuarantineState,
        generation: UInt64
    ) async throws {
        try requireActive(generation)
        let recoverableRecordNames = quarantine.entries
            .filter { $0.value.attemptCount < Self.maximumQuarantineAttempts }
            .keys
            .sorted()
            .prefix(Self.quarantineRecoveryBatchLimit)
        guard !recoverableRecordNames.isEmpty else { return }

        let fetched: CloudKitFetchedRecords
        do {
            fetched = try await database.fetchRecords(
                for: Array(recoverableRecordNames),
                in: zoneID
            )
        } catch {
            try requireActive(generation)
            syncLog.error(
                "quarantined record re-fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        try requireActive(generation)

        for recordName in fetched.permanentlyMissingRecordNames.sorted() {
            syncLog.info(
                "dropping quarantined record \(recordName, privacy: .public); CloudKit no longer has it"
            )
            quarantine.clear(recordName)
        }
        for record in fetched.records {
            try requireActive(generation)
            try await accumulateRemoteRecord(
                record,
                into: store,
                accumulation: &accumulation,
                quarantine: &quarantine,
                generation: generation
            )
        }
    }

    /// Per-record server failures split by kind: a record CloudKit permanently no longer has is
    /// quarantined and skipped, anything retryable still aborts the pull so the change token is not
    /// advanced past data the server merely failed to hand over this time.
    private func quarantinePermanentServerFailures(
        _ failures: [CloudKitRecordFailure],
        quarantine: inout QuarantineState
    ) throws {
        var retryableCount = 0
        for failure in failures {
            guard Self.isPermanentServerRecordFailure(failure.error) else {
                retryableCount += 1
                continue
            }
            quarantine.record(failure.recordName, reason: failure.error.localizedDescription)
        }
        guard retryableCount == 0 else {
            throw CloudKitSyncError.partialRecordFailures(retryableCount)
        }
    }

    private nonisolated static func isPermanentServerRecordFailure(_ error: any Error) -> Bool {
        cloudKitErrorCode(of: error) == .unknownItem
    }

    /// A resolution failure is permanent when replaying the same record can only fail the same way:
    /// the record's blob is absent from CloudKit, oversized, or unusable as a local file. Local
    /// environment failures (a blob that cannot be written right now) stay fatal, so the token is
    /// held and the record is retried instead of being skipped past.
    private nonisolated static func isPermanentRecordResolutionFailure(_ error: any Error) -> Bool {
        if let syncError = error as? CloudKitSyncError, case .missingBlobAsset = syncError {
            return true
        }
        guard let blobError = error as? SyncBlobStorage.Error else { return false }
        switch blobError {
        case .notRegularFile, .unsafeFilename, .oversizedBlob:
            return true
        }
    }

    private nonisolated static let unmappableRecordReason =
        "Record fields cannot be read as a clip."

    private nonisolated static let maximumQuarantineAttempts = 5

    private nonisolated static let quarantineRecoveryBatchLimit = 100

    private enum RemoteItemResolution {
        case available(
            item: ClipboardItem,
            blob: SyncBlobReference?,
            requiresLocalRepush: Bool
        )
        case missingAssetShadowedByLocalTombstone(
            item: ClipboardItem,
            blob: SyncBlobReference
        )
    }

    private func resolveRemoteItem(
        from record: CKRecord,
        into store: SyncableStore,
        generation: UInt64
    ) async throws -> RemoteItemResolution? {
        try requireActive(generation)
        guard let item = ClipboardCloudMapping.item(from: record) else { return nil }
        if !item.isDeleted,
           let blob = item.syncBlobReference,
           (record[ClipboardCloudMapping.Key.blob] as? CKAsset)?.fileURL == nil,
           Self.localTombstoneDominates(item, in: store.itemsForSync()) {
            syncLog.info(
                "skipping missing asset for clip \(item.id.uuidString, privacy: .public) because a local tombstone dominates"
            )
            return .missingAssetShadowedByLocalTombstone(item: item, blob: blob)
        }
        switch try await resolveRemoteBlob(
            from: record,
            for: item,
            into: store,
            generation: generation
        ) {
        case .notRequired:
            return .available(item: item, blob: nil, requiresLocalRepush: false)
        case .available(let blob, let requiresLocalRepush):
            return .available(
                item: item,
                blob: blob,
                requiresLocalRepush: requiresLocalRepush
            )
        }
    }

    private nonisolated static func localTombstoneDominates(
        _ remoteItem: ClipboardItem,
        in localItems: [ClipboardItem]
    ) -> Bool {
        let sameIDItems = localItems.filter { $0.id == remoteItem.id }
        guard let localWinner = ClipboardMerge.reconcile(sameIDItems, []).first else {
            return false
        }
        return localWinner.isDeleted && localWinner.modifiedAt >= remoteItem.modifiedAt
    }

    private nonisolated static func isExpiredChangeTokenError(_ error: any Error) -> Bool {
        cloudKitErrorCode(of: error) == .changeTokenExpired
    }

    private nonisolated static func cloudKitErrorCode(of error: any Error) -> CKError.Code? {
        if let cloudKitError = error as? CKError {
            return cloudKitError.code
        }
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return nil }
        return CKError.Code(rawValue: nsError.code)
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
        // Both halves are attempted before either failure is reported: the settings record is
        // independent of the clip batches, so a failing clip batch must not strand a limit the
        // user chose in the same session (nor the reverse).
        var clipError: (any Error)?
        do {
            try await pushLocalClips(store: store, generation: generation)
        } catch {
            clipError = error
        }

        if settingsReconciliationPending, canMutate(generation) {
            do {
                try await reconcileSettings(generation: generation)
            } catch {
                // The clip failure came first and is the more consequential one to surface.
                if clipError == nil { clipError = error }
            }
        }

        if let clipError { throw clipError }
    }

    private func pushLocalClips(store: SyncableStore, generation: UInt64) async throws {
        try requireActive(generation)
        let local = store.itemsForSync()
        let isReceiptMigration = pushReceipts == nil

        let existingReceipts = pushReceipts ?? [:]
        let itemsToPush = Self.itemsNeedingPush(local, receipts: pushReceipts)
        let currentItemIDs = Set(local.map(\.id))
        let garbageCollectedReceipts = existingReceipts.filter { currentItemIDs.contains($0.key) }

        try requireActive(generation)
        let prepared = Self.preparePushRecords(itemsToPush, in: zoneID) { item in
            item.isDeleted ? nil : existingBlobURL(for: item)
        }
        // A clip CloudKit cannot represent (blob file gone, unusable blob metadata) is skipped
        // instead of blocking every other pending record. It keeps no receipt, so an ordinary
        // later push replays it once the local state is repaired.
        for skippedID in prepared.skippedItemIDs {
            syncLog.error("skipping clip with invalid sync blob metadata: \(skippedID.uuidString, privacy: .public)")
        }
        guard !prepared.records.isEmpty else {
            if isReceiptMigration || garbageCollectedReceipts != existingReceipts {
                try persistPushReceipts(garbageCollectedReceipts, generation: generation)
            }
            return
        }

        try requireActive(generation)
        var committedReceipts = existingReceipts
        // Receipts land per accepted batch: a later batch failure must not strand the records
        // CloudKit already took, which would otherwise be re-uploaded by every future push.
        try await savePreparedRecords(prepared.records, generation: generation) { batch in
            let canonicalItemIDs = Set(store.itemsForSync().map(\.id))
            committedReceipts = committedReceipts.filter { canonicalItemIDs.contains($0.key) }
            for pushed in batch where canonicalItemIDs.contains(pushed.itemID) {
                committedReceipts[pushed.itemID] = pushed.modifiedAt
            }
            try persistPushReceipts(committedReceipts, generation: generation)
        }
    }

    // MARK: - Synced settings

    /// What to do with the settings record after reading the server's copy. Pure and total, so
    /// the last-writer-wins rule is decided in one place and tested without a network.
    enum SettingsResolution: Equatable {
        case idle
        case adopt(SyncedSettings)
        case publish
    }

    /// Last-writer-wins, with two guards that matter more than the happy path:
    /// a remote record this build *cannot read* still defends its slot by stamp alone, and a
    /// limit the local user never chose is never published.
    nonisolated static func settingsResolution(
        local: SyncedSettings,
        remote: RemoteSettingsRecord?
    ) -> SettingsResolution {
        if let remoteSettings = remote?.settings, remoteSettings.updatedAt > local.updatedAt {
            return .adopt(remoteSettings)
        }
        if let remote, local.updatedAt <= remote.updatedAt {
            // Older or tied — including against a value this build cannot interpret. The
            // incumbent remote stands and this device stays quiet.
            return .idle
        }
        guard local.wasChosen else { return .idle }
        return .publish
    }

    /// Reconciles the singleton settings record fetch-first: read the server's copy, decide, and
    /// save *that instance* so the conditional save carries a real change tag. A conflict is then
    /// a genuine mid-flight race rather than the guaranteed cost of every publish.
    private func reconcileSettings(generation: UInt64) async throws {
        try requireActive(generation)
        guard settingsStore?.syncedSettings != nil else { return }

        for _ in 0..<Self.maximumSettingsSaveAttempts {
            try requireActive(generation)
            guard let local = settingsStore?.syncedSettings else { return }
            let serverRecord = try await fetchSettingsRecord(generation: generation)
            try requireActive(generation)

            switch Self.settingsResolution(
                local: local,
                remote: serverRecord.flatMap(SyncedSettingsCloudMapping.remoteRecord(from:))
            ) {
            case .idle:
                settingsReconciliationPending = false
                return
            case .adopt(let remote):
                settingsStore?.applySyncedSettings(remote)
                settingsReconciliationPending = false
                return
            case .publish:
                let record: CKRecord
                if let serverRecord {
                    SyncedSettingsCloudMapping.apply(local, to: serverRecord)
                    record = serverRecord
                } else {
                    record = SyncedSettingsCloudMapping.record(for: local, in: zoneID)
                }
                if try await database.saveRecordIfUnchanged(record) == .saved {
                    try requireActive(generation)
                    settingsReconciliationPending = false
                    return
                }
                // Someone wrote between the fetch and the save. Re-read and re-decide; if they
                // are newer, adopting their value *is* the resolution.
                try requireActive(generation)
            }
        }
        // Losing the race repeatedly is not a sync failure — nothing is lost, and the next
        // trigger re-decides against whatever the server settled on.
        syncLog.info("settings record kept changing mid-save; leaving it for the next sync")
    }

    private func fetchSettingsRecord(generation: UInt64) async throws -> CKRecord? {
        let fetched = try await database.fetchRecords(
            for: [SyncedSettingsCloudMapping.recordName],
            in: zoneID
        )
        try requireActive(generation)
        return fetched.records.first { $0.recordType == SyncedSettingsCloudMapping.recordType }
    }

    /// Live fast path for a settings record arriving in the change feed, so another device's
    /// choice lands without waiting for the next launch. Purely an accelerator: the fetch-first
    /// reconcile is what guarantees convergence, which is why an unreadable record here is
    /// simply ignored rather than held onto.
    private func applySettingsFromChangeFeed(_ remote: SyncedSettings) {
        guard let settingsStore, let local = settingsStore.syncedSettings else { return }
        guard remote.updatedAt > local.updatedAt else { return }
        settingsStore.applySyncedSettings(remote)
    }

    private nonisolated static let maximumSettingsSaveAttempts = 2

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
        generation: UInt64,
        afterBatch: ([PreparedPushRecord]) throws -> Void = { _ in }
    ) async throws {
        for batch in records.chunked(into: 100) {
            let result = try await database.saveRecords(batch.map(\.record))
            try requireActive(generation)
            guard result.failedRecordNames.isEmpty else {
                throw CloudKitSyncError.partialRecordSaves(result.failedRecordNames.count)
            }
            try afterBatch(batch)
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
        // Settings need no equivalent invalidation: every reconcile reads the server's copy
        // first, so there is no cached acknowledgement that could go stale.
        settingsReconciliationPending = true
    }

    private static func loadPushReceipts(
        from defaults: UserDefaults,
        key: String
    ) -> [UUID: Date]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? CloudKitPushReceiptCodec.decode(data)
    }

    private func persistPullQuarantine(
        _ entries: [String: CloudKitPullQuarantineEntry],
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: pullQuarantineKey)
            pullQuarantine = [:]
            return
        }
        guard let data = try? CloudKitPullQuarantineCodec.encode(entries) else {
            throw CloudKitSyncError.pullQuarantineEncodingFailed
        }
        try requireActive(generation)
        defaults.set(data, forKey: pullQuarantineKey)
        pullQuarantine = entries
    }

    /// A quarantine list that cannot be read is treated as empty: the affected records simply
    /// re-quarantine themselves on the next pull.
    private static func loadPullQuarantine(
        from defaults: UserDefaults,
        key: String
    ) -> [String: CloudKitPullQuarantineEntry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? CloudKitPullQuarantineCodec.decode(data)) ?? [:]
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
