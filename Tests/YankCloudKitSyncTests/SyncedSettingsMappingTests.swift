import Foundation
import CloudKit
import Testing
@testable import YankCore
@testable import YankCloudKitSync

/// Offline `SyncedSettings ⇄ CKRecord` round-trip and the rejection rules that keep an
/// unusable remote value from resizing someone's history.
@Suite @MainActor
struct SyncedSettingsMappingTests {
    private let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)

    @Test func recordRoundTripsThroughTheSingletonRecordName() throws {
        let settings = SyncedSettings(
            historyLimit: .deep,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_234)
        )

        let record = SyncedSettingsCloudMapping.record(for: settings, in: zoneID)

        #expect(record.recordType == "SyncedSettings")
        #expect(record.recordID.recordName == "settings")
        #expect(record.recordID.zoneID == zoneID)
        #expect(SyncedSettingsCloudMapping.settings(from: record) == settings)
    }

    @Test func historyLimitOutsideTheKnownTiersIsRejected() throws {
        let record = CKRecord(
            recordType: "SyncedSettings",
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        record["historyLimit"] = 777
        record["updatedAt"] = Date(timeIntervalSinceReferenceDate: 1_234)

        #expect(SyncedSettingsCloudMapping.settings(from: record) == nil)
    }

    @Test func missingFieldsAreRejected() throws {
        let noStamp = CKRecord(
            recordType: "SyncedSettings",
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        noStamp["historyLimit"] = 100

        let noLimit = CKRecord(
            recordType: "SyncedSettings",
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        noLimit["updatedAt"] = Date(timeIntervalSinceReferenceDate: 1_234)

        #expect(SyncedSettingsCloudMapping.settings(from: noStamp) == nil)
        #expect(SyncedSettingsCloudMapping.settings(from: noLimit) == nil)
    }

    @Test func aClipRecordIsNeverReadAsSettings() throws {
        let clip = CKRecord(
            recordType: ClipboardCloudMapping.recordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        clip["historyLimit"] = 100
        clip["updatedAt"] = Date(timeIntervalSinceReferenceDate: 1_234)

        #expect(SyncedSettingsCloudMapping.settings(from: clip) == nil)
    }

    @Test func applyOverwritesAnExistingRecordInPlace() throws {
        let original = SyncedSettings(
            historyLimit: .essential,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let replacement = SyncedSettings(
            historyLimit: .unlimited,
            updatedAt: Date(timeIntervalSinceReferenceDate: 900)
        )
        let record = SyncedSettingsCloudMapping.record(for: original, in: zoneID)

        SyncedSettingsCloudMapping.apply(replacement, to: record)

        #expect(SyncedSettingsCloudMapping.settings(from: record) == replacement)
    }
}
