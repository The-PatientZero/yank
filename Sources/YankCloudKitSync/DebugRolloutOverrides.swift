#if DEBUG
import Foundation
import CloudKit
import os

/// Debug-only launch arguments that let the encryption rollout be proven without waiting days.
/// Each is read by presence, so a value of `0` counts as set. Compiled out of Release builds.
enum DebugRolloutOverrides {
    private static func integer(_ name: String) -> Int? {
        guard UserDefaults.standard.object(forKey: name) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: name)
    }

    private static func seconds(_ name: String) -> TimeInterval? {
        integer(name).map { TimeInterval($0) }
    }

    static var soakSeconds: TimeInterval? { seconds("yankRolloutSoakSeconds") }
    static var legacyActivityWindowSeconds: TimeInterval? { seconds("yankLegacyActivityWindowSeconds") }
    static var evaluationIntervalSeconds: TimeInterval? { seconds("yankRolloutEvaluationIntervalSeconds") }
    static var sweepPageSize: Int? { integer("yankSweepPageSize").map { max($0, 1) } }
    static var stopSweepAfterPages: Int? { integer("yankStopSweepAfterPages") }
    static var recordBudgetBytes: Int? { integer("yankRecordBudgetBytes") }

    static var simulateDeviceZoneFailure: Bool {
        ProcessInfo.processInfo.arguments.contains("-yankSimulateDeviceZoneFailure")
    }

    static var logRecordShapes: Bool {
        ProcessInfo.processInfo.arguments.contains("-yankLogRecordShapes")
    }
}

/// Makes every request against the devices zone fail, so the proof can show that a broken device
/// registry never breaks clip sync. Requests for other zones pass through unchanged.
@MainActor
final class DeviceZoneFailureInjectingDatabase: CloudKitDatabase {
    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "Simulated device zone failure." }
    }

    private let base: any CloudKitDatabase

    init(wrapping base: any CloudKitDatabase) {
        self.base = base
    }

    private func isDevicesZone(_ zoneID: CKRecordZone.ID) -> Bool {
        zoneID.zoneName == CloudKitDeviceRegistry.zoneName
    }

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        if isDevicesZone(zoneID) { throw InjectedFailure() }
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
        if isDevicesZone(zoneID) { throw InjectedFailure() }
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
        if isDevicesZone(zoneID) { throw InjectedFailure() }
        return try await base.fetchRecordPresence(for: recordNames, in: zoneID)
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID,
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> CloudKitFetchedRecords {
        if isDevicesZone(zoneID) { throw InjectedFailure() }
        return try await base.fetchRecords(for: recordNames, in: zoneID, desiredKeys: desiredKeys)
    }

    func saveRecords(
        _ records: [CKRecord],
        savePolicy: CloudKitSavePolicy
    ) async throws -> CloudKitRecordSaveResult {
        if records.contains(where: { isDevicesZone($0.recordID.zoneID) }) { throw InjectedFailure() }
        return try await base.saveRecords(records, savePolicy: savePolicy)
    }

    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        if isDevicesZone(record.recordID.zoneID) { throw InjectedFailure() }
        return try await base.saveRecordIfUnchanged(record)
    }
}

extension CloudKitSyncService {
    /// Logs one line per touched record: which readable content keys it still holds and how big
    /// its encrypted copy is. Names and counts only, never values.
    func logRecordShapes(for recordNames: [String]) async {
        guard DebugRolloutOverrides.logRecordShapes, !recordNames.isEmpty else { return }
        for batch in Set(recordNames).sorted().chunkedForShapes(100) {
            do {
                let fetched = try await database.fetchRecords(
                    for: batch,
                    in: zoneID,
                    desiredKeys: ClipboardCloudMapping.contentFetchKeys
                )
                for record in fetched.records {
                    let plainKeys = ClipboardCloudMapping.plainContentKeys.filter {
                        Self.holdsValue(record[$0])
                    }
                    let encBytes = (record.encryptedValues[ClipboardCloudMapping.Key.encContent] as? Data)?.count ?? 0
                    let name = String(record.recordID.recordName.prefix(8))
                    syncLog.info(
                        "record shape \(name, privacy: .public): plain content keys [\(plainKeys.joined(separator: ", "), privacy: .public)], encContent \(encBytes, privacy: .public) bytes"
                    )
                }
            } catch {
                syncLog.error("record shape fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func holdsValue(_ value: (any CKRecordValue)?) -> Bool {
        guard let value else { return false }
        if let list = value as? [String] { return !list.isEmpty }
        return true
    }
}

private extension Array {
    func chunkedForShapes(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
#endif
