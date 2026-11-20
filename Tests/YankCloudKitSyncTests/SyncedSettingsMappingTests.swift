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

    @Test func retentionDaysRoundTripsWithTheRecord() throws {
        let settings = SyncedSettings(
            historyLimit: .deep,
            retentionDays: 30,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_234)
        )

        let record = SyncedSettingsCloudMapping.record(for: settings, in: zoneID)

        #expect(record["retentionDays"] as? Int == 30)
        #expect(SyncedSettingsCloudMapping.settings(from: record) == settings)
    }

    /// Records written before retention synced carry no opinion — the read degrades to `nil`
    /// instead of rejecting the record or inventing a default.
    @Test func aRecordWithoutRetentionStillReadsWithNoOpinion() throws {
        let record = CKRecord(
            recordType: "SyncedSettings",
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        record["historyLimit"] = 500
        record["updatedAt"] = Date(timeIntervalSinceReferenceDate: 1_234)

        let settings = try #require(SyncedSettingsCloudMapping.settings(from: record))
        #expect(settings.retentionDays == nil)
    }

    @Test func aNegativeRetentionValueReadsAsNoOpinion() throws {
        let record = CKRecord(
            recordType: "SyncedSettings",
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        record["historyLimit"] = 500
        record["retentionDays"] = -5
        record["updatedAt"] = Date(timeIntervalSinceReferenceDate: 1_234)

        let settings = try #require(SyncedSettingsCloudMapping.settings(from: record))
        #expect(settings.retentionDays == nil)
    }

    /// Publishing through a fetched record must not erase a retention value another build
    /// wrote when this device has none of its own.
    @Test func applyWithoutARetentionOpinionLeavesTheStoredValueAlone() throws {
        let withRetention = SyncedSettings(
            historyLimit: .essential,
            retentionDays: 30,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let withoutOpinion = SyncedSettings(
            historyLimit: .unlimited,
            updatedAt: Date(timeIntervalSinceReferenceDate: 900)
        )
        let record = SyncedSettingsCloudMapping.record(for: withRetention, in: zoneID)

        SyncedSettingsCloudMapping.apply(withoutOpinion, to: record)

        #expect(record["retentionDays"] as? Int == 30)
        #expect(SyncedSettingsCloudMapping.settings(from: record)?.historyLimit == .unlimited)
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
