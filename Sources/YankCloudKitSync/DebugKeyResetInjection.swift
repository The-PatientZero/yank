#if DEBUG
import Foundation
import CloudKit

/// Debug-only wrapper that makes the live database report an encrypted-data key reset once from
/// a zone fetch and once from a save, so the recovery path can be watched without resetting a
/// real iCloud account. Active only when the process is launched with `launchArgument`.
@MainActor
final class KeyResetInjectingDatabase: CloudKitDatabase {
    static let launchArgument = "-yankSimulateEncryptedDataKeyReset"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

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
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        if fetchPending {
            fetchPending = false
            throw Self.resetError
        }
        return try await base.fetchZoneChanges(zoneID, since: token)
    }

    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence {
        try await base.fetchRecordPresence(for: recordNames, in: zoneID)
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords {
        try await base.fetchRecords(for: recordNames, in: zoneID)
    }

    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult {
        if savePending, !records.isEmpty {
            savePending = false
            return CloudKitRecordSaveResult(
                failedRecordNames: records.map(\.recordID.recordName).sorted(),
                encryptedDataKeyWasReset: true
            )
        }
        return try await base.saveRecords(records)
    }

    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        try await base.saveRecordIfUnchanged(record)
    }
}
#endif
