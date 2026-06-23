import Foundation
import CloudKit
import Testing
@testable import YankCore
@testable import YankCloudKitSync

/// Exercises the `CloudKitSyncService` orchestration through the `CloudKitDatabase` seam:
/// zone/subscription bring-up, paginated pull → `ClipboardMerge` → apply, watermarked +
/// chunked push, token clearing, and start failure — all against an in-memory fake.
@Suite @MainActor
struct CloudKitSyncServiceTests {
    private let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)

    // MARK: - Bring-up

    @Test func startEnsuresZoneAndSubscriptionThenReports() async throws {
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = makeService(database: database, store: store)

        let result = await service.start()

        #expect(result == .started)
        #expect(database.ensuredZone)
        #expect(database.ensuredSubscription)
    }

    @Test func startSurfacesFailureMessageWhenZoneSetupThrows() async {
        let database = FakeCloudKitDatabase()
        database.ensureZoneError = TestError.boom
        let service = makeService(database: database, store: FakeSyncableStore())

        let result = await service.start()

        guard case .failed(let message) = result else {
            Issue.record("Expected start to fail when zone setup throws")
            return
        }
        #expect(!message.isEmpty)
        #expect(database.savedBatches.isEmpty)
    }

    // MARK: - Pull → merge → apply

    @Test func pullMergesRemoteRecordsIntoTheStore() async throws {
        let remote = makeTextItem(text: "from-cloud", modifiedAt: 500)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        let service = makeService(database: database, store: store)

        _ = await service.start()

        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == remote.id && $0.textContent == "from-cloud" })
    }

    @Test func pullTurnsRemoteDeletionsIntoTombstones() async throws {
        let existing = makeTextItem(text: "doomed", modifiedAt: 100)
        let store = FakeSyncableStore()
        store.items = [existing]
        let database = FakeCloudKitDatabase()
        database.pages = [page(deletedNames: [existing.id.uuidString], moreComing: false)]
        let service = makeService(database: database, store: store)

        _ = await service.start()

        let applied = try #require(store.appliedReconciled)
        let merged = try #require(applied.first { $0.id == existing.id })
        #expect(merged.isDeleted)
    }

    @Test func pullPaginatesAcrossMoreComing() async throws {
        let first = makeTextItem(text: "page-1", modifiedAt: 100)
        let second = makeTextItem(text: "page-2", modifiedAt: 200)
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(changed: [try record(for: first)], moreComing: true),
            page(changed: [try record(for: second)], moreComing: false)
        ]
        let store = FakeSyncableStore()
        let service = makeService(database: database, store: store)

        _ = await service.start()

        #expect(database.fetchCount == 2)
        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == first.id })
        #expect(applied.contains { $0.id == second.id })
    }

    @Test func pullDeletesDownloadedBlobWhenReconcileDropsRemoteItem() async throws {
        let id = UUID()
        let filename = "\(UUID().uuidString).txt"
        let remote = makeLargeTextItem(id: id, filename: filename, modifiedAt: 100)
        let tombstone = makeTombstone(id: id, modifiedAt: 200)
        let assetURL = try writeAsset("remote blob")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let store = FakeSyncableStore()
        store.items = [tombstone]
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote, blobURL: assetURL)], moreComing: false)]
        let service = makeService(database: database, store: store)

        _ = await service.start()

        #expect(store.writtenBlobs == [blob])
        #expect(store.deletedBlobs == [blob])
        #expect(store.items.first?.isDeleted == true)
    }

    @Test func pullKeepsDownloadedBlobWhenReconciledItemSurvives() async throws {
        let filename = "\(UUID().uuidString).txt"
        let remote = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let assetURL = try writeAsset("kept blob")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let store = FakeSyncableStore()
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote, blobURL: assetURL)], moreComing: false)]
        let service = makeService(database: database, store: store)

        _ = await service.start()

        #expect(store.writtenBlobs == [blob])
        #expect(store.deletedBlobs.isEmpty)
        #expect(store.items.contains { $0.id == remote.id })
    }

    @Test func pullFailsWithoutApplyingOrAdvancingTokenWhenBlobWriteFails() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let filename = "\(UUID().uuidString).txt"
        let remote = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let assetURL = try writeAsset("lost blob")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote, blobURL: assetURL)], moreComing: false)]
        let store = FakeSyncableStore()
        store.writeBlobError = TestError.boom
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected failed start when a required blob cannot be written")
            return
        }
        #expect(store.appliedReconciled == nil)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
    }

    // MARK: - Remote change

    @Test func remoteChangeReportsSuccessOnlyAfterPullApplies() async throws {
        let remote = makeTextItem(text: "background-push", modifiedAt: 500)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        let service = makeService(database: database, store: store)

        let completed = await service.handleRemoteChange()

        #expect(completed)
        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == remote.id && $0.textContent == "background-push" })
    }

    // MARK: - Push (watermark + chunking)

    @Test func pushSendsOnlyItemsNewerThanThePersistedWatermark() async throws {
        let stale = makeTextItem(text: "stale", modifiedAt: 100)
        let fresh = makeTextItem(text: "fresh", modifiedAt: 300)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 200),
                     forKey: "cloudkit.lastPushedModifiedAt.\(containerID)")

        let store = FakeSyncableStore()
        store.items = [stale, fresh]
        let database = FakeCloudKitDatabase()
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        _ = await service.start()

        let pushed = database.savedBatches.flatMap { $0 }
        #expect(pushed.count == 1)
        #expect(pushed.first?.recordID.recordName == fresh.id.uuidString)
        // Watermark advances to the newest pushed item.
        #expect(defaults.object(forKey: "cloudkit.lastPushedModifiedAt.\(containerID)") as? Date
                == Date(timeIntervalSinceReferenceDate: 300))
    }

    @Test func pushChunksLargeBatchesIntoGroupsOf100() async throws {
        let store = FakeSyncableStore()
        store.items = (0..<150).map { makeTextItem(text: "item-\($0)", modifiedAt: Double(1000 + $0)) }
        let database = FakeCloudKitDatabase()
        let service = makeService(database: database, store: store)

        _ = await service.start()

        #expect(database.savedBatches.count == 2)
        #expect(database.savedBatches.map(\.count) == [100, 50])
    }

    @Test func startSkipsPushWhenNoLocalItemsAreDirty() async throws {
        let database = FakeCloudKitDatabase()
        let service = makeService(database: database, store: FakeSyncableStore())

        _ = await service.start()

        #expect(database.savedBatches.isEmpty)
    }

    // MARK: - Change token

    @Test func pullClearsAStaleChangeTokenWhenNoneIsReturned() async {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)

        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        _ = await service.start()

        #expect(defaults.data(forKey: tokenKey) == nil)
    }

    @Test func pullClearsChangeTokenOnlyAfterDurableStoreApply() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let remote = makeTextItem(text: "from-cloud", modifiedAt: 500)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        var tokenDataDuringDurableApply: Data?
        store.onApplyReconciledDurably = {
            tokenDataDuringDurableApply = defaults.data(forKey: tokenKey)
        }
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        _ = await service.start()

        #expect(tokenDataDuringDurableApply == staleTokenData)
        #expect(defaults.data(forKey: tokenKey) == nil)
    }

    @Test func startRetriesFromScratchAndReuploadsLocalItemsWhenChangeTokenExpired() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)
        defaults.set(Date(timeIntervalSinceReferenceDate: 1_000), forKey: watermarkKey)
        let local = makeTextItem(text: "local-only", modifiedAt: 100)
        let database = FakeCloudKitDatabase()
        database.fetchErrors = [expiredChangeTokenError()]
        database.pages = [page(moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [local]
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        let result = await service.start()

        #expect(result == .started)
        #expect(database.fetchCount == 2)
        #expect(defaults.data(forKey: tokenKey) == nil)
        let pushed = database.savedBatches.flatMap { $0 }
        #expect(pushed.map(\.recordID.recordName) == [local.id.uuidString])
        #expect(defaults.object(forKey: watermarkKey) as? Date == local.modifiedAt)
    }

    @Test func remoteChangeReuploadsLocalItemsWhenChangeTokenExpired() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 1_000),
                     forKey: "cloudkit.lastPushedModifiedAt.\(containerID)")
        let local = makeTextItem(text: "local-after-remote-token-reset", modifiedAt: 100)
        let database = FakeCloudKitDatabase()
        database.fetchErrors = [expiredChangeTokenError()]
        database.pages = [page(moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [local]
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        let completed = await service.handleRemoteChange()

        #expect(completed)
        #expect(database.fetchCount == 2)
        let pushed = database.savedBatches.flatMap { $0 }
        #expect(pushed.map(\.recordID.recordName) == [local.id.uuidString])
    }

    // MARK: - Helpers

    private func makeService(database: any CloudKitDatabase, store: SyncableStore) -> CloudKitSyncService {
        CloudKitSyncService(
            containerIdentifier: "test.\(UUID().uuidString)",
            store: store,
            database: database,
            defaults: isolatedDefaults()
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CloudKitSyncServiceTests.\(UUID().uuidString)")!
    }

    private func makeTextItem(text: String, modifiedAt: TimeInterval) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: modifiedAt),
            textContent: text,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt)
        )
    }

    private func makeLargeTextItem(id: UUID, filename: String, modifiedAt: TimeInterval) -> ClipboardItem {
        ClipboardItem(
            id: id,
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: modifiedAt),
            textFilename: filename,
            isTruncated: false,
            originalSizeBytes: 1_024,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt)
        )
    }

    private func makeTombstone(id: UUID, modifiedAt: TimeInterval) -> ClipboardItem {
        let date = Date(timeIntervalSinceReferenceDate: modifiedAt)
        return ClipboardItem(id: id, type: .text, timestamp: date, modifiedAt: date, deletedAt: date)
    }

    private func record(for item: ClipboardItem, blobURL: URL? = nil) throws -> CKRecord {
        try #require(ClipboardCloudMapping.record(from: item, in: zoneID, blobURL: blobURL))
    }

    private func writeAsset(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankCloudKitSyncServiceTests-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func expiredChangeTokenError() -> any Error {
        NSError(domain: CKError.errorDomain, code: CKError.Code.changeTokenExpired.rawValue)
    }

    private func page(
        changed: [CKRecord] = [],
        deletedNames: [String] = [],
        moreComing: Bool
    ) -> CloudKitZoneChanges {
        CloudKitZoneChanges(
            changedRecords: changed,
            deletedRecordNames: deletedNames,
            changeToken: nil,
            moreComing: moreComing
        )
    }
}

private enum TestError: Error { case boom }

/// In-memory `CloudKitDatabase`: returns the configured zone-change pages in order, records
/// every saved batch, and can be told to fail bring-up. `@MainActor` to match the seam.
@MainActor
private final class FakeCloudKitDatabase: CloudKitDatabase {
    var pages: [CloudKitZoneChanges] = []
    var ensureZoneError: (any Error)?
    var fetchErrors: [any Error] = []
    var saveError: (any Error)?

    private(set) var ensuredZone = false
    private(set) var ensuredSubscription = false
    private(set) var savedBatches: [[CKRecord]] = []
    private(set) var fetchCount = 0
    private var pageIndex = 0

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        if let ensureZoneError { throw ensureZoneError }
        ensuredZone = true
    }

    func ensureSubscription(id subscriptionID: String) async throws {
        ensuredSubscription = true
    }

    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        fetchCount += 1
        if !fetchErrors.isEmpty {
            throw fetchErrors.removeFirst()
        }
        guard pageIndex < pages.count else {
            return CloudKitZoneChanges(changedRecords: [], deletedRecordNames: [],
                                       changeToken: token, moreComing: false)
        }
        defer { pageIndex += 1 }
        return pages[pageIndex]
    }

    func saveRecords(_ records: [CKRecord]) async throws {
        if let saveError { throw saveError }
        savedBatches.append(records)
    }
}

/// In-memory `SyncableStore` capturing the reconciled snapshot the service applies.
@MainActor
private final class FakeSyncableStore: SyncableStore {
    var items: [ClipboardItem] = []
    var onApplyReconciledDurably: (() -> Void)?
    private(set) var appliedReconciled: [ClipboardItem]?
    private(set) var writtenBlobs: [SyncBlobReference] = []
    private(set) var deletedBlobs: [SyncBlobReference] = []
    private(set) var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)
    var writeBlobError: (any Error)?

    func itemsForSync() -> [ClipboardItem] { items }

    func applyReconciled(_ canonical: [ClipboardItem]) {
        appliedReconciled = canonical
        items = canonical
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) {
        applyReconciled(canonical)
        onApplyReconciledDurably?()
    }

    func blobURL(for reference: SyncBlobReference) -> URL? { nil }

    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws {
        if let writeBlobError { throw writeBlobError }
        writtenBlobs.append(reference)
    }

    func deleteBlob(_ reference: SyncBlobReference) {
        deletedBlobs.append(reference)
    }

    func markSyncStarted() { syncStatus = .syncing }
    func markSyncSucceeded(at date: Date) { syncStatus = .healthy(lastSynced: date) }
    func markSyncFailed(_ message: String) { syncStatus = .failed(message: message) }
    func markSyncUnavailable(reason: SyncStatus.Reason) { syncStatus = .localOnly(reason: reason) }
}
