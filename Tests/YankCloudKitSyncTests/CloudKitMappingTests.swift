import Foundation
import CloudKit
import Testing
@testable import YankCore
@testable import YankCloudKitSync

@Suite struct CloudKitMappingTests {
    private let safeImageFilename = "11111111-1111-4111-8111-111111111111.png"
    private let safeTextFilename = "22222222-2222-4222-8222-222222222222.txt"

    @Test func scalarRoundTrip() throws {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let original = ClipboardItem(
            id: UUID(),
            type: .image,
            timestamp: Date(timeIntervalSinceReferenceDate: 1000),
            sourceApp: "Safari",
            imageFilename: safeImageFilename,
            isPinned: true,
            isBookmarked: false,
            tags: ["work", "urgent"],
            ocrText: "extracted",
            isTruncated: false,
            originalSizeBytes: 2048,
            searchIndex: ClipboardSearchIndex.make(for: "synced searchable text"),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2000),
            deletedAt: nil,
            deviceOrigin: "device-A"
        )

        let record = try #require(ClipboardCloudMapping.record(from: original, in: zoneID))
        let restored = try #require(ClipboardCloudMapping.item(from: record))

        #expect(restored.id == original.id)
        #expect(restored.type == original.type)
        #expect(restored.timestamp == original.timestamp)
        #expect(restored.sourceApp == original.sourceApp)
        #expect(restored.imageFilename == original.imageFilename)
        #expect(restored.isPinned == original.isPinned)
        #expect(restored.isBookmarked == original.isBookmarked)
        #expect(restored.tags == original.tags)
        #expect(restored.ocrText == original.ocrText)
        #expect(restored.originalSizeBytes == original.originalSizeBytes)
        #expect(restored.searchIndex == original.searchIndex)
        #expect(restored.modifiedAt == original.modifiedAt)
        #expect(restored.deviceOrigin == original.deviceOrigin)
        #expect(record.recordID.recordName == original.id.uuidString)
    }

    @Test func tombstoneRoundTrip() throws {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let tombstone = ClipboardItem(id: UUID(), type: .text, timestamp: Date(), modifiedAt: Date(), deletedAt: Date())
        let record = try #require(ClipboardCloudMapping.record(from: tombstone, in: zoneID))
        #expect(ClipboardCloudMapping.item(from: record)?.isDeleted == true)
    }

    @Test func itemsNeedingPushUsesPersistedWatermark() {
        let old = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "old",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let fresh = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 200),
            textContent: "fresh",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
        )

        let dirty = CloudKitSyncService.itemsNeedingPush(
            [old, fresh],
            since: Date(timeIntervalSinceReferenceDate: 150)
        )

        #expect(dirty == [fresh])
        #expect(CloudKitSyncService.itemsNeedingPush([old, fresh], since: nil) == [old, fresh])
    }

    @Test func pushWatermarkOnlyAdvancesOverMappedRecords() {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let valid = ClipboardItem(
            id: clipID(1),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            textContent: "valid",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let invalidNewer = ClipboardItem(
            id: clipID(2),
            type: .image,
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            imageFilename: "nested/\(safeImageFilename)",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
        )

        let prepared = CloudKitSyncService.preparePushRecords([valid, invalidNewer], in: zoneID) { _ in nil }

        #expect(prepared.records.count == 1)
        #expect(prepared.records.first?.record.recordID.recordName == valid.id.uuidString)
        #expect(prepared.skippedItemIDs == [invalidNewer.id])
        #expect(CloudKitSyncService.pushedWatermark(afterPushing: prepared.records) == valid.modifiedAt)
    }

    @Test func rejectsPathBearingBlobFilenamesFromCloudKit() {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: ClipboardCloudMapping.recordType, recordID: recordID)
        record[ClipboardCloudMapping.Key.type] = ClipboardItemType.text.rawValue
        record[ClipboardCloudMapping.Key.timestamp] = Date()
        record[ClipboardCloudMapping.Key.modifiedAt] = Date()
        record[ClipboardCloudMapping.Key.textFilename] = "../history.json"

        #expect(ClipboardCloudMapping.item(from: record) == nil)
    }

    @Test func rejectsMismatchedCloudKitBlobKind() {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: ClipboardCloudMapping.recordType, recordID: recordID)
        record[ClipboardCloudMapping.Key.type] = ClipboardItemType.text.rawValue
        record[ClipboardCloudMapping.Key.timestamp] = Date()
        record[ClipboardCloudMapping.Key.modifiedAt] = Date()
        record[ClipboardCloudMapping.Key.imageFilename] = safeImageFilename

        #expect(ClipboardCloudMapping.item(from: record) == nil)
    }

    @Test func refusesRecordsForUnsafeLocalBlobFilenames() {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let item = ClipboardItem(
            id: UUID(),
            type: .image,
            timestamp: Date(),
            imageFilename: "nested/\(safeImageFilename)"
        )

        #expect(ClipboardCloudMapping.record(from: item, in: zoneID) == nil)
    }

    @Test func hasRichContentRoundTripsViaCloudKit() throws {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let original = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 1000),
            textContent: "rich text",
            hasRichContent: true,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2000)
        )
        let record = try #require(ClipboardCloudMapping.record(from: original, in: zoneID))
        let restored = try #require(ClipboardCloudMapping.item(from: record))
        #expect(restored.hasRichContent == true)
    }

    @Test func hasRichContentDefaultsFalseWhenAbsentInCloudKit() throws {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: ClipboardCloudMapping.recordType, recordID: recordID)
        record[ClipboardCloudMapping.Key.type] = ClipboardItemType.text.rawValue
        record[ClipboardCloudMapping.Key.timestamp] = Date()
        record[ClipboardCloudMapping.Key.modifiedAt] = Date()
        record[ClipboardCloudMapping.Key.textContent] = "legacy"
        let item = try #require(ClipboardCloudMapping.item(from: record))
        #expect(item.hasRichContent == false)
    }

    @Test func aiFieldsRoundTripViaCloudKit() throws {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let original = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: 1000),
            textContent: "a long passage worth a title",
            aiTags: ["aws", "billing"],
            aiTitle: "AWS billing summary",
            aiEnrichedAt: Date(timeIntervalSinceReferenceDate: 1500),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2000)
        )
        let record = try #require(ClipboardCloudMapping.record(from: original, in: zoneID))
        let restored = try #require(ClipboardCloudMapping.item(from: record))
        #expect(restored.aiTags == original.aiTags)
        #expect(restored.aiTitle == original.aiTitle)
        #expect(restored.aiEnrichedAt == original.aiEnrichedAt)
    }

    @Test func aiFieldsDefaultWhenAbsentInCloudKit() throws {
        let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: ClipboardCloudMapping.recordType, recordID: recordID)
        record[ClipboardCloudMapping.Key.type] = ClipboardItemType.text.rawValue
        record[ClipboardCloudMapping.Key.timestamp] = Date()
        record[ClipboardCloudMapping.Key.modifiedAt] = Date()
        record[ClipboardCloudMapping.Key.textContent] = "legacy record from a pre-AI build"
        let item = try #require(ClipboardCloudMapping.item(from: record))
        #expect(item.aiTags.isEmpty)
        #expect(item.aiTitle == nil)
        #expect(item.aiEnrichedAt == nil)
    }

    @Test func blobPolicyAcceptsGeneratedBasenamesOnly() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let safeURL = try #require(SyncBlobPolicy.containedURL(
            directory: base,
            filename: safeTextFilename,
            kind: .text
        ))

        #expect(safeURL.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path)
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: "../history.json", kind: .text) == nil)
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: safeImageFilename, kind: .text) == nil)
        #expect(SyncBlobPolicy.containedURL(directory: base, filename: "not-a-uuid.txt", kind: .text) == nil)
    }

    @Test func syncBlobReaderRejectsOversizedFilesBeforeReturningData() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("asset.bin")
        try Data(repeating: 0, count: 5).write(to: url)

        do {
            _ = try await SyncBlobStorage.read(from: url, maxBytes: 4)
            Issue.record("Expected oversized synced blob read to throw")
        } catch let error as SyncBlobStorage.Error {
            #expect(error == .oversizedBlob(actualBytes: 5, maxBytes: 4))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let data = try await SyncBlobStorage.read(from: url, maxBytes: 5)
        #expect(data.count == 5)
    }
}

private func clipID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}
