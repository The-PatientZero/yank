import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

/// Outcome of `CloudKitSyncService.start()`: sync came up, or it failed with a
/// user-presentable message.
public enum CloudKitSyncStartResult: Equatable, Sendable {
    /// Sync came up.
    case started
    /// Sync did not come up; `message` is safe to show to a person.
    case failed(message: String)
}

/// Plain-data view of one page of zone changes, so the sync engine can be exercised with a
/// fake (`CKDatabase.RecordZoneChanges` isn't constructible outside CloudKit). Its non-`Sendable`
/// `CKRecord`s stay safe: the `CloudKitDatabase` seam is `@MainActor`, so they never cross actors.
struct CloudKitZoneChanges {
    var changedRecords: [CKRecord]
    var deletedRecordNames: [String]
    /// Records the server acknowledged but could not hand over. The error is carried so the pull
    /// can tell a permanently gone record (skip it) from a transient failure (hold the token).
    var failedRecords: [CloudKitRecordFailure] = []
    var changeToken: CKServerChangeToken?
    var moreComing: Bool
    /// The page was requested without the file field, so its records carry no `CKAsset` whether
    /// or not iCloud holds a file for them.
    var assetsOmitted = false
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
    /// At least one record failed because the user reset their encrypted-data key.
    var encryptedDataKeyWasReset = false
}

struct CloudKitRecordSaveResult {
    var failedRecordNames: [String] = []
    /// Records a conditional save rejected because the server's copy moved on. Not part of
    /// `failedRecordNames`: the caller decides whether to retry them.
    var conflictedRecordNames: [String] = []
    /// At least one record failed because the user reset their encrypted-data key.
    var encryptedDataKeyWasReset = false
    /// The most actionable cause among the failed records, when CloudKit reported one.
    var failure: SyncFailure?
}

/// CloudKit reports a reset of the user's encrypted-data key as a `zoneNotFound` error whose
/// `userInfo` carries `CKErrorUserDidResetEncryptedDataKey`; there is no error code of its own.
/// The zone and everything in it is gone on the server, so recovery is re-creating the zone and
/// uploading from local history.
enum CloudKitEncryptedDataKeyReset {
    static func isReset(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        if nsError.code == CKError.Code.zoneNotFound.rawValue,
           (nsError.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?.boolValue == true {
            return true
        }
        guard nsError.code == CKError.Code.partialFailure.rawValue,
              let itemErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] else {
            return false
        }
        return itemErrors.values.contains { isReset($0) }
    }
}

/// Outcome of a conditional (`.ifServerRecordUnchanged`) save. `conflict` means the server's
/// copy moved on since the record being saved was fetched — the caller has to re-read it and
/// decide who wins rather than blindly overwriting.
enum CloudKitConditionalSaveOutcome: Equatable {
    case saved
    case conflict
}

/// How a batch save treats the server's copy of each record.
enum CloudKitSavePolicy: Equatable {
    /// Last writer wins, sending only the keys that changed on the record.
    case changedKeys
    /// A record whose server copy changed since it was fetched is rejected and reported.
    case ifServerRecordUnchanged
}

struct CloudKitRecordPresence {
    var presentRecordNames: Set<String> = []
    var missingRecordNames: Set<String> = []
}

/// The CloudKit operations `CloudKitSyncService` depends on, abstracted as a seam (DIP) so the
/// full pull → `ClipboardMerge` → apply → push pipeline is unit-tested against an in-memory
/// fake. `@MainActor` keeps `CKRecord` on the service's actor, avoiding `Sendable` laundering.
@MainActor
protocol CloudKitDatabase {
    func ensureZone(_ zoneID: CKRecordZone.ID) async throws
    func ensureSubscription(id subscriptionID: String) async throws
    /// `desiredKeys` limits the downloaded fields (nil downloads all, assets included);
    /// `resultsLimit` caps the records in one page.
    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int?
    ) async throws -> CloudKitZoneChanges
    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence
    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID,
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> CloudKitFetchedRecords
    func saveRecords(
        _ records: [CKRecord],
        savePolicy: CloudKitSavePolicy
    ) async throws -> CloudKitRecordSaveResult
    /// Save one record only while the server's copy still matches the change tag it carries.
    /// Separate from `saveRecords` because the clip path deliberately uses `.changedKeys`
    /// last-writer-wins, while the singleton settings record must never clobber a newer remote.
    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome
}

extension CloudKitDatabase {
    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        try await fetchZoneChanges(zoneID, since: token, desiredKeys: nil, resultsLimit: nil)
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords {
        try await fetchRecords(for: recordNames, in: zoneID, desiredKeys: nil)
    }

    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult {
        try await saveRecords(records, savePolicy: .changedKeys)
    }
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
        } catch let saveError as CKError where saveError.code == .serverRejectedRequest {
            // Usually "already exists", but the same code covers genuine rejections. Only a
            // fetch proving the subscription is in place makes the error safe to swallow —
            // otherwise the device silently loses push delivery.
            do {
                _ = try await self.subscription(for: subscriptionID)
            } catch {
                throw saveError
            }
        }
    }

    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int?
    ) async throws -> CloudKitZoneChanges {
        let changes = try await recordZoneChanges(
            inZoneWith: zoneID,
            since: token,
            desiredKeys: desiredKeys,
            resultsLimit: resultsLimit
        )
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
            moreComing: changes.moreComing,
            assetsOmitted: desiredKeys.map { !$0.contains(ClipboardCloudMapping.Key.blob) } ?? false
        )
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID,
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> CloudKitFetchedRecords {
        let recordIDs = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let results = try await records(for: recordIDs, desiredKeys: desiredKeys)
        var fetched = CloudKitFetchedRecords()
        fetched.records.reserveCapacity(results.count)
        for (recordID, result) in results {
            switch result {
            case .success(let record):
                fetched.records.append(record)
            case .failure(let error) where Self.isUnknownItemError(error):
                fetched.permanentlyMissingRecordNames.insert(recordID.recordName)
            case .failure(let error) where CloudKitEncryptedDataKeyReset.isReset(error):
                fetched.encryptedDataKeyWasReset = true
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

    func saveRecords(
        _ records: [CKRecord],
        savePolicy: CloudKitSavePolicy
    ) async throws -> CloudKitRecordSaveResult {
        let results = try await modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: savePolicy == .changedKeys ? .changedKeys : .ifServerRecordUnchanged
        )
        var failedRecordNames = Set<String>()
        var conflictedRecordNames = Set<String>()
        var failureErrors: [any Error] = []
        for (recordID, result) in results.saveResults {
            guard case .failure(let error) = result else { continue }
            if savePolicy == .ifServerRecordUnchanged, Self.isServerRecordChangedError(error) {
                conflictedRecordNames.insert(recordID.recordName)
            } else {
                failedRecordNames.insert(recordID.recordName)
                failureErrors.append(error)
            }
        }
        let encryptedDataKeyWasReset = results.saveResults.values.contains { result in
            if case .failure(let error) = result { return CloudKitEncryptedDataKeyReset.isReset(error) }
            return false
        }
        let requestedRecordNames = Set(records.map(\.recordID.recordName))
        let returnedRecordNames = Set(results.saveResults.keys.map(\.recordName))
        failedRecordNames.formUnion(requestedRecordNames.subtracting(returnedRecordNames))
        return CloudKitRecordSaveResult(
            failedRecordNames: failedRecordNames.sorted(),
            conflictedRecordNames: conflictedRecordNames.sorted(),
            encryptedDataKeyWasReset: encryptedDataKeyWasReset,
            failure: CloudKitSyncFailureClassifier.classify(itemErrors: failureErrors)
        )
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
