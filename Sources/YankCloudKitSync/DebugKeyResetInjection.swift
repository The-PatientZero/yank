#if DEBUG
import Foundation
import CloudKit

/// Debug-only wrapper that makes the live database report an encrypted-data key reset once from
/// a zone fetch and once from a save, so the recovery path can be watched without resetting a
/// real iCloud account. Active only when the process is launched with `launchArgument`. Only
/// requests for the clip zone are affected: the device registry zone is a separate zone that a
/// reset of the encrypted-data key does not turn into a recovery for clip sync.
@MainActor
final class KeyResetInjectingDatabase: CloudKitDatabase {
    static let launchArgument = "-yankSimulateEncryptedDataKeyReset"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private static let clipZoneName = "YankZone"

    private let base: any CloudKitDatabase
    private var fetchPending = true
    private var savePending = true

    init(wrapping base: any CloudKitDatabase) {
        self.base = base
    }

    private static var resetError: NSError {
        NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.zoneNotFound.rawValue,
            userInfo: [CKErrorUserDidResetEncryptedDataKey: NSNumber(value: true)]
        )
    }

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        try await base.ensureZone(zoneID)
    }

    func ensureSubscription(id subscriptionID: String) async throws {
        try await base.ensureSubscription(id: subscriptionID)
    }

    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int?
    ) async throws -> CloudKitZoneChanges {
        if fetchPending, zoneID.zoneName == Self.clipZoneName {
            fetchPending = false
            throw Self.resetError
        }
        return try await base.fetchZoneChanges(
            zoneID,
            since: token,
            desiredKeys: desiredKeys,
            resultsLimit: resultsLimit
        )
    }

    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence {
        try await base.fetchRecordPresence(for: recordNames, in: zoneID)
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID,
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> CloudKitFetchedRecords {
        try await base.fetchRecords(for: recordNames, in: zoneID, desiredKeys: desiredKeys)
    }

    func saveRecords(
        _ records: [CKRecord],
        savePolicy: CloudKitSavePolicy
    ) async throws -> CloudKitRecordSaveResult {
        if savePending, records.contains(where: { $0.recordID.zoneID.zoneName == Self.clipZoneName }) {
            savePending = false
            return CloudKitRecordSaveResult(
                failedRecordNames: records.map(\.recordID.recordName).sorted(),
                encryptedDataKeyWasReset: true
            )
        }
        return try await base.saveRecords(records, savePolicy: savePolicy)
    }

    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        try await base.saveRecordIfUnchanged(record)
    }
}
#endif
