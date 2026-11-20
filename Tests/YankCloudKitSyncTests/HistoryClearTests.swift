import Foundation
import CloudKit
import Testing
@testable import YankCore
@testable import YankCloudKitSync

/// A queued "clear history" must tombstone every older clip iCloud holds, including clips this
/// device never had, without blocking uploads or pulls while it cannot finish.
@Suite @MainActor
struct HistoryClearTests {
    private let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
    private let hour: TimeInterval = 3_600

    @MainActor
    private struct Harness {
        let service: CloudKitSyncService
        let database: FakeCloudKitDatabase
        let store: FakeSyncableStore
        let defaults: UserDefaults
        let containerID: String

        var intentKey: String { "cloudkit.historyClear.\(containerID)" }
        var intentIsPending: Bool { defaults.object(forKey: intentKey) is Date }
        var savedRecords: [CKRecord] { database.savedBatches.flatMap { $0 } }

        func savedRecord(named name: String) -> CKRecord? {
            savedRecords.last { $0.recordID.recordName == name }
        }
    }

    @Test func remoteOnlyClipOlderThanRequestIsTombstonedAndIntentRemoved() async throws {
        let harness = makeHarness()
        let remote = clip(text: "only in iCloud", age: -hour)
        harness.database.pages = [scanPage([try record(for: remote)])]
        CloudKitSyncService.requestHistoryClear(
            containerIdentifier: harness.containerID, defaults: harness.defaults
        )

        let result = await harness.service.start()

        #expect(result == .started)
        let saved = try #require(harness.savedRecord(named: remote.id.uuidString))
        #expect(saved[ClipboardCloudMapping.Key.deletedAt] as? Date != nil)
        #expect(saved[ClipboardCloudMapping.Key.textContent] == nil)
        #expect(!harness.intentIsPending)
    }

    @Test func clipNewerThanRequestIsNotTombstoned() async throws {
        let harness = makeHarness()
        let newer = clip(text: "copied after the clear", age: hour)
        harness.database.pages = [scanPage([try record(for: newer)])]
        CloudKitSyncService.requestHistoryClear(
            containerIdentifier: harness.containerID, defaults: harness.defaults
        )

        _ = await harness.service.start()

        #expect(harness.savedRecord(named: newer.id.uuidString) == nil)
        #expect(!harness.intentIsPending)
    }

    @Test func existingDeletionWithoutContentIsNotSavedAgain() async throws {
        let harness = makeHarness()
        let deleted = ClipboardItem(
            id: UUID(), type: .text, timestamp: Date(timeIntervalSinceNow: -hour),
            modifiedAt: Date(timeIntervalSinceNow: -hour), deletedAt: Date(timeIntervalSinceNow: -hour)
        )
        harness.database.pages = [scanPage([try record(for: deleted)])]
        CloudKitSyncService.requestHistoryClear(
            containerIdentifier: harness.containerID, defaults: harness.defaults
        )

        _ = await harness.service.start()

        #expect(harness.savedRecord(named: deleted.id.uuidString) == nil)
        #expect(!harness.intentIsPending)
    }

    @Test func permanentlyMissingRecordDoesNotStopTheClear() async throws {
        let harness = makeHarness()
        let remote = clip(text: "still tombstoned", age: -hour)
        harness.database.pages = [
            scanPage(
                [try record(for: remote)],
                failedRecords: [permanentFailure(UUID().uuidString)]
            )
        ]
        CloudKitSyncService.requestHistoryClear(
            containerIdentifier: harness.containerID, defaults: harness.defaults
        )

        let result = await harness.service.start()

        #expect(result == .started)
        #expect(harness.savedRecord(named: remote.id.uuidString) != nil)
        #expect(!harness.intentIsPending)
    }

    @Test func retryableFailureKeepsIntentPendingWhileLocalClipsStillUpload() async throws {
        let harness = makeHarness()
        let local = clip(text: "copied after the clear", age: hour)
        harness.store.items = [local]
        let failingPage = scanPage([], failedRecords: [retryableFailure()])
        harness.database.pages = Array(repeating: failingPage, count: 20)
        CloudKitSyncService.requestHistoryClear(
            containerIdentifier: harness.containerID, defaults: harness.defaults
        )

        _ = await harness.service.start()

        #expect(harness.intentIsPending)
        #expect(harness.savedRecord(named: local.id.uuidString) != nil)
    }

    @Test func syncedSettingsRecordIsNeverTombstonedByTheScan() async throws {
        let harness = makeHarness()
        let settings = CKRecord(
            recordType: SyncedSettingsCloudMapping.recordType,
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        let updatedAt = Date(timeIntervalSinceNow: -hour)
        settings[SyncedSettingsCloudMapping.Key.historyLimit] = 500
        settings[SyncedSettingsCloudMapping.Key.updatedAt] = updatedAt
        harness.database.pages = [scanPage([settings])]
        CloudKitSyncService.requestHistoryClear(
            containerIdentifier: harness.containerID, defaults: harness.defaults
        )

        _ = await harness.service.start()

        #expect(harness.savedRecord(named: SyncedSettingsCloudMapping.recordName) == nil)
        #expect(settings[ClipboardCloudMapping.Key.deletedAt] == nil)
        #expect(settings[SyncedSettingsCloudMapping.Key.historyLimit] as? Int == 500)
        #expect(settings[SyncedSettingsCloudMapping.Key.updatedAt] as? Date == updatedAt)
        #expect(!harness.intentIsPending)
    }

    private func makeHarness() -> Harness {
        let containerID = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: "HistoryClearTests.\(UUID().uuidString)")!
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            settingsStore: nil,
            defaults: defaults
        )
        return Harness(
            service: service, database: database, store: store,
            defaults: defaults, containerID: containerID
        )
    }

    /// `age` is seconds from now: negative is older than a clear requested right now.
    private func clip(text: String, age: TimeInterval) -> ClipboardItem {
        let date = Date(timeIntervalSinceNow: age)
        return ClipboardItem(
            id: UUID(), type: .text, timestamp: date, textContent: text, modifiedAt: date
        )
    }

    private func record(for item: ClipboardItem) throws -> CKRecord {
        try #require(ClipboardCloudMapping.record(from: item, in: zoneID, blobURL: nil))
    }

    private func scanPage(
        _ records: [CKRecord],
        failedRecords: [CloudKitRecordFailure] = []
    ) -> CloudKitZoneChanges {
        CloudKitZoneChanges(
            changedRecords: records,
            deletedRecordNames: [],
            failedRecords: failedRecords,
            changeToken: nil,
            moreComing: false
        )
    }

    private func permanentFailure(_ recordName: String) -> CloudKitRecordFailure {
        CloudKitRecordFailure(
            recordName: recordName,
            error: NSError(domain: CKError.errorDomain, code: CKError.Code.unknownItem.rawValue)
        )
    }

    private func retryableFailure() -> CloudKitRecordFailure {
        CloudKitRecordFailure(
            recordName: UUID().uuidString,
            error: NSError(domain: CKError.errorDomain, code: CKError.Code.networkFailure.rawValue)
        )
    }
}
