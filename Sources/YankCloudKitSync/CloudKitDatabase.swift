import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

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
