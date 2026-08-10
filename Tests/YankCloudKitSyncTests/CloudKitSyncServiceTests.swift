import Foundation
import CloudKit
import Testing
@testable import YankCore
@testable import YankCloudKitSync

/// Exercises the `CloudKitSyncService` orchestration through the `CloudKitDatabase` seam:
/// zone/subscription bring-up, paginated pull → `ClipboardMerge` → apply, receipt-driven +
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

    @Test func pullHoldsTheTokenWhenAServerRecordFailureIsRetryable() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let remote = makeTextItem(text: "partial-page-success", modifiedAt: 500)
        let database = FakeCloudKitDatabase()
        database.pages = [page(
            changed: [try record(for: remote)],
            failedRecords: [retryableRecordFailure()],
            moreComing: false
        )]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected a retryable partial pull page to fail sync")
            return
        }
        #expect(store.appliedReconciled == nil)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID).isEmpty)
        #expect(database.savedBatches.isEmpty)
    }

    @Test func pullQuarantinesAPermanentlyMissingServerRecordAndAdvancesTheToken() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)
        let remote = makeTextItem(text: "healthy-sibling", modifiedAt: 500)
        let goneRecordName = UUID().uuidString
        let database = FakeCloudKitDatabase()
        database.pages = [page(
            changed: [try record(for: remote)],
            failedRecords: [permanentRecordFailure(goneRecordName)],
            moreComing: false
        )]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == remote.id })
        #expect(defaults.data(forKey: tokenKey) == nil)
        let quarantine = try pullQuarantine(defaults: defaults, containerID: containerID)
        #expect(quarantine[goneRecordName]?.attemptCount == 1)
        #expect(quarantine[goneRecordName]?.reason.isEmpty == false)
    }

    @Test func partialLaterPageCleansUpPreviouslyDownloadedUnreferencedBlobs() async throws {
        let filename = "\(UUID().uuidString).txt"
        let remote = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let assetURL = try writeAsset("pending blob")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(changed: [try record(for: remote, blobURL: assetURL)], moreComing: true),
            page(failedRecords: [retryableRecordFailure()], moreComing: false)
        ]
        let store = FakeSyncableStore()
        let service = makeService(database: database, store: store)

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected the partial later page to fail sync")
            return
        }
        #expect(store.appliedReconciled == nil)
        let staged = try #require(store.writtenBlobs.first)
        #expect(staged != blob)
        #expect(store.deletedBlobs == [staged, blob])
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

        let staged = try #require(store.writtenBlobs.first)
        #expect(staged != blob)
        #expect(store.deletedBlobs == [staged, blob])
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

        let staged = try #require(store.writtenBlobs.first)
        #expect(staged != blob)
        #expect(store.deletedBlobs == [staged])
        #expect(store.blobURL(for: blob).map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true)
        #expect(store.items.contains { $0.id == remote.id })
    }

    @Test func poisonRecordIsQuarantinedWhileHealthyRecordsApplyAndTheTokenAdvances() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)
        let poison = makeLargeTextItem(
            id: UUID(),
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let available = makeTextItem(text: "available", modifiedAt: 200)
        let database = FakeCloudKitDatabase()
        database.pages = [page(
            changed: [try record(for: poison), try record(for: available)],
            moreComing: false
        )]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == available.id })
        #expect(!applied.contains { $0.id == poison.id })
        #expect(store.writtenBlobs.isEmpty)
        #expect(defaults.data(forKey: tokenKey) == nil)
        let quarantine = try pullQuarantine(defaults: defaults, containerID: containerID)
        #expect(Array(quarantine.keys) == [poison.id.uuidString])
        #expect(quarantine[poison.id.uuidString]?.attemptCount == 1)
    }

    @Test func quarantinedRecordIsRecoveredOnALaterSuccessfulFetch() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let filename = "\(UUID().uuidString).txt"
        let poison = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let recoveredAssetURL = try writeAsset("recovered blob")
        defer { try? FileManager.default.removeItem(at: recoveredAssetURL) }
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: poison)], moreComing: false)]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        #expect(await service.start() == .started)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID)
                .keys.contains(poison.id.uuidString))

        database.fetchableRecords[poison.id.uuidString] =
            try record(for: poison, blobURL: recoveredAssetURL)
        let recoveredResult = await service.start()

        #expect(recoveredResult == .started)
        #expect(database.fetchedRecordNameBatches == [[poison.id.uuidString]])
        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == poison.id })
        let staged = try #require(store.writtenBlobs.first)
        #expect(staged != blob)
        #expect(store.deletedBlobs == [staged])
        #expect(store.blobURL(for: blob).map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID).isEmpty)
        #expect(defaults.data(forKey: tokenKey) == nil)
    }

    @Test func quarantineRecoveryStopsAtTheAttemptCapButKeepsTheRecordListed() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let poison = makeLargeTextItem(
            id: UUID(),
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: poison)], moreComing: false)]
        // The re-fetch keeps returning the same unresolvable record.
        database.fetchableRecords[poison.id.uuidString] = try record(for: poison)
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        for _ in 0..<8 {
            #expect(await service.start() == .started)
        }

        #expect(database.fetchedRecordNameBatches.count == 4)
        let quarantine = try pullQuarantine(defaults: defaults, containerID: containerID)
        #expect(quarantine[poison.id.uuidString]?.attemptCount == 5)
        #expect(store.writtenBlobs.isEmpty)
    }

    @Test func quarantinedRecordDroppedWhenCloudKitNoLongerHasIt() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let poison = makeLargeTextItem(
            id: UUID(),
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: poison)], moreComing: false)]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        #expect(await service.start() == .started)
        database.permanentlyMissingFetchRecordNames = [poison.id.uuidString]
        #expect(await service.start() == .started)

        #expect(try pullQuarantine(defaults: defaults, containerID: containerID).isEmpty)
    }

    @Test func quarantineRecoveryFetchFailureLeavesTheEntryUntouched() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let remote = makeTextItem(text: "healthy", modifiedAt: 200)
        let poison = makeLargeTextItem(
            id: UUID(),
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(changed: [try record(for: poison)], moreComing: false),
            page(changed: [try record(for: remote)], moreComing: false)
        ]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        #expect(await service.start() == .started)
        database.fetchRecordsError = TestError.boom
        let result = await service.start()

        #expect(result == .started)
        #expect(store.appliedReconciled?.contains { $0.id == remote.id } == true)
        let quarantine = try pullQuarantine(defaults: defaults, containerID: containerID)
        #expect(quarantine[poison.id.uuidString]?.attemptCount == 1)
    }

    @Test func pullBypassesMissingAssetWhenNewerLocalTombstoneDominates() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let id = UUID()
        let remote = makeLargeTextItem(
            id: id,
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let tombstone = makeTombstone(id: id, modifiedAt: 200)
        try setPushReceipts(
            [id: tombstone.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [tombstone]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(store.writtenBlobs.isEmpty)
        let applied = try #require(store.appliedReconciled)
        let winner = try #require(applied.first { $0.id == id })
        #expect(winner.isDeleted)
        #expect(winner.modifiedAt == tombstone.modifiedAt)
        let pushed = try #require(database.savedBatches.flatMap { $0 }.first)
        #expect(pushed.recordID.recordName == id.uuidString)
        #expect(pushed[ClipboardCloudMapping.Key.deletedAt] as? Date == tombstone.deletedAt)
        #expect(pushed[ClipboardCloudMapping.Key.blob] == nil)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[id]
                == tombstone.modifiedAt)
        #expect(defaults.data(forKey: tokenKey) == nil)
    }

    @Test func pullBypassesMissingAssetWhenDeletionWinsEqualClock() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let id = UUID()
        let remote = makeLargeTextItem(
            id: id,
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let tombstone = makeTombstone(id: id, modifiedAt: 100)
        try setPushReceipts(
            [id: tombstone.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [tombstone]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let applied = try #require(store.appliedReconciled)
        #expect(applied.first { $0.id == id }?.isDeleted == true)
        let pushed = try #require(database.savedBatches.flatMap { $0 }.first)
        #expect(pushed[ClipboardCloudMapping.Key.deletedAt] as? Date == tombstone.deletedAt)
        #expect(pushed[ClipboardCloudMapping.Key.blob] == nil)
    }

    @Test func missingAssetRemoteNewerThanTheLocalTombstoneIsQuarantined() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)
        let id = UUID()
        let remote = makeLargeTextItem(
            id: id,
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 200
        )
        let tombstone = makeTombstone(id: id, modifiedAt: 100)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [tombstone]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let applied = try #require(store.appliedReconciled)
        let winner = try #require(applied.first { $0.id == id })
        #expect(winner.isDeleted)
        #expect(winner.modifiedAt == tombstone.modifiedAt)
        #expect(store.writtenBlobs.isEmpty)
        #expect(defaults.data(forKey: tokenKey) == nil)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID)[id.uuidString]?
                .attemptCount == 1)
    }

    @Test func pullFailsClosedWhenDominatingTombstoneDisappearsBeforeReconciliation() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let id = UUID()
        let remote = makeLargeTextItem(
            id: id,
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let tombstone = makeTombstone(id: id, modifiedAt: 200)
        try setPushReceipts(
            [id: tombstone.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(changed: [try record(for: remote)], moreComing: true),
            page(moreComing: false)
        ]
        let store = FakeSyncableStore()
        store.items = [tombstone]
        var fetchCount = 0
        database.onFetchZoneChanges = {
            fetchCount += 1
            if fetchCount == 2 {
                store.items = []
            }
        }
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected final tombstone revalidation to fail closed")
            return
        }
        #expect(store.appliedReconciled == nil)
        #expect(store.writtenBlobs.isEmpty)
        #expect(database.savedBatches.isEmpty)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[id]
                == tombstone.modifiedAt)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
    }

    @Test func startupPullRepairsAMissingCloudKitAssetWhenTheLocalBlobStillExists() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("recoverable blob")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        let existingWatermark = Date(timeIntervalSinceReferenceDate: 1_000)
        defaults.set(existingWatermark, forKey: watermarkKey)
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let repaired = try #require(database.savedBatches.flatMap { $0 }.first)
        #expect(repaired.recordID.recordName == item.id.uuidString)
        #expect(repaired[ClipboardCloudMapping.Key.blob] is CKAsset)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id] == item.modifiedAt)
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func repairReceiptInvalidationSurvivesInterruptionAndServiceRecreation() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("repair-after-recreation")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let interruptedDatabase = FakeCloudKitDatabase()
        interruptedDatabase.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let interruptedService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: interruptedDatabase,
            defaults: defaults,
            afterReceiptInvalidationBeforeTokenPersistence: {
                #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id] == nil)
                #expect(defaults.data(forKey: tokenKey) == staleTokenData)
                throw TestError.boom
            }
        )

        let interruptedResult = await interruptedService.start()

        guard case .failed = interruptedResult else {
            Issue.record("Expected interruption after durable repair receipt invalidation")
            return
        }
        #expect(store.appliedReconciled != nil)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id] == nil)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
        #expect(interruptedDatabase.savedBatches.isEmpty)

        let recreatedDatabase = FakeCloudKitDatabase()
        let recreatedService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: recreatedDatabase,
            defaults: defaults
        )
        let recreatedResult = await recreatedService.start()

        #expect(recreatedResult == .started)
        let repaired = try #require(recreatedDatabase.savedBatches.flatMap { $0 }.first)
        #expect(repaired.recordID.recordName == item.id.uuidString)
        #expect(repaired[ClipboardCloudMapping.Key.blob] is CKAsset)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func repairSaveFailureLeavesReceiptAbsentForARecreatedRetry() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("repair-after-save-failure")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let failingDatabase = FakeCloudKitDatabase()
        failingDatabase.pages = [page(changed: [try record(for: item)], moreComing: false)]
        failingDatabase.failedSaveRecordNames = [item.id.uuidString]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let failingService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: failingDatabase,
            defaults: defaults
        )

        let failed = await failingService.handleRemoteChange()

        #expect(!failed)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id] == nil)

        let retryDatabase = FakeCloudKitDatabase()
        let retryService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: retryDatabase,
            defaults: defaults
        )
        let retried = await retryService.start()

        #expect(retried == .started)
        #expect(retryDatabase.savedBatches.flatMap { $0 }.map(\.recordID.recordName)
                == [item.id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func missingRemoteAssetWithoutALocalBlobIsQuarantinedAndTheTokenAdvances() async throws {
        let item = makeLargeTextItem(
            id: UUID(),
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(store.appliedReconciled?.isEmpty == true)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID)[item.id.uuidString]?
                .attemptCount == 1)
        #expect(defaults.data(forKey: tokenKey) == nil)
        #expect(database.savedBatches.isEmpty)
    }

    @Test func repairReceiptIsNotInvalidatedWhenDurableApplyFails() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("apply-failure")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        store.durableApplyError = TestError.boom
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected the durable apply failure to abort repair")
            return
        }
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
        #expect(database.savedBatches.isEmpty)
    }

    @Test func repairReceiptIsNotInvalidatedWhenALaterPullPageFails() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("page-failure")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(changed: [try record(for: item)], moreComing: true),
            page(failedRecords: [retryableRecordFailure()], moreComing: false)
        ]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected the partial later page to abort repair")
            return
        }
        #expect(store.appliedReconciled == nil)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
        #expect(database.savedBatches.isEmpty)
    }

    @Test func repairReceiptPersistenceFailureLeavesReceiptAndTokenUntouched() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("receipt-persistence-failure")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            beforeReceiptPersistence: { throw TestError.boom }
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected repair receipt persistence to fail the pull")
            return
        }
        #expect(store.appliedReconciled != nil)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
        #expect(database.savedBatches.isEmpty)
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

    @Test func ordinaryRemoteChangeRepairsAMissingAssetFromReceiptState() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("ordinary-repair")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let completed = await service.handleRemoteChange()

        #expect(completed)
        let repaired = try #require(database.savedBatches.flatMap { $0 }.first)
        #expect(repaired.recordID.recordName == item.id.uuidString)
        #expect(repaired[ClipboardCloudMapping.Key.blob] is CKAsset)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func cleanOrdinaryRemoteChangeDoesNotSaveAnyRecords() async throws {
        let item = makeTextItem(text: "already-synced", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([item.id: item.modifiedAt], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [item]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let completed = await service.handleRemoteChange()

        #expect(completed)
        #expect(database.savedBatches.isEmpty)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func nilReceiptMigrationStateStillRepairsAndCommitsAReceipt() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("migration-repair")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            afterReceiptInvalidationBeforeTokenPersistence: {
                #expect(defaults.data(forKey: pushReceiptsKey(containerID)) == nil)
            }
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName)
                == [item.id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func alreadyAbsentRecordReceiptStillTriggersOrdinaryRepair() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let localURL = try writeAsset("already-invalidated-repair")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([:], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: item)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [item]
        store.blobURLs[blob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let completed = await service.handleRemoteChange()

        #expect(completed)
        let repaired = try #require(database.savedBatches.flatMap { $0 }.first)
        #expect(repaired.recordID.recordName == item.id.uuidString)
        #expect(repaired[ClipboardCloudMapping.Key.blob] is CKAsset)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    // MARK: - Push receipts

    @Test func futureDatedRecordDoesNotSuppressAnotherRecordsInsertEditOrDelete() async throws {
        let future = makeTextItem(id: UUID(), text: "future", modifiedAt: 10_000)
        let edited = makeTextItem(id: UUID(), text: "edited", modifiedAt: 300)
        let inserted = makeTextItem(id: UUID(), text: "inserted", modifiedAt: 150)
        let deleted = makeTombstone(id: UUID(), modifiedAt: 175)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts(
            [
                future.id: future.modifiedAt,
                edited.id: Date(timeIntervalSinceReferenceDate: 200),
                deleted.id: Date(timeIntervalSinceReferenceDate: 100)
            ],
            defaults: defaults,
            containerID: containerID
        )

        let store = FakeSyncableStore()
        store.items = [future, edited, inserted, deleted]
        let database = FakeCloudKitDatabase()
        let service = CloudKitSyncService(containerIdentifier: containerID, store: store,
                                          database: database, defaults: defaults)

        let result = await service.start()

        let pushed = database.savedBatches.flatMap { $0 }
        #expect(result == .started)
        #expect(Set(pushed.map(\.recordID.recordName)) == [
            edited.id.uuidString,
            inserted.id.uuidString,
            deleted.id.uuidString
        ])
        let persistedReceipts = try pushReceipts(
            defaults: defaults,
            containerID: containerID
        )
        let receipts = try #require(persistedReceipts)
        #expect(receipts[future.id] == future.modifiedAt)
        #expect(receipts[edited.id] == edited.modifiedAt)
        #expect(receipts[inserted.id] == inserted.modifiedAt)
        #expect(receipts[deleted.id] == deleted.modifiedAt)
    }

    @Test func sameRecordClockRollbackRemainsDirty() async throws {
        let id = UUID()
        let rolledBack = makeTextItem(id: id, text: "clock-corrected", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts(
            [id: Date(timeIntervalSinceReferenceDate: 1_000)],
            defaults: defaults,
            containerID: containerID
        )
        let store = FakeSyncableStore()
        store.items = [rolledBack]
        let database = FakeCloudKitDatabase()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName) == [id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[id]
                == rolledBack.modifiedAt)
    }

    @Test func receiptGarbageCollectionUsesTheCurrentCanonicalSet() async throws {
        let retained = makeTextItem(text: "retained", modifiedAt: 100)
        let orphanID = UUID()
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts(
            [
                retained.id: retained.modifiedAt,
                orphanID: Date(timeIntervalSinceReferenceDate: 200)
            ],
            defaults: defaults,
            containerID: containerID
        )
        let store = FakeSyncableStore()
        store.items = [retained]
        let database = FakeCloudKitDatabase()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(database.savedBatches.isEmpty)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)
                == [retained.id: retained.modifiedAt])
    }

    @Test func hardRemoteDeletionProducesADirtyTombstoneReceipt() async throws {
        let local = makeTextItem(text: "delete-remotely", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts(
            [local.id: local.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(deletedNames: [local.id.uuidString], moreComing: false)
        ]
        let store = FakeSyncableStore()
        store.items = [local]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let pushed = try #require(database.savedBatches.flatMap { $0 }.first)
        let pushedVersion = try #require(
            pushed[ClipboardCloudMapping.Key.modifiedAt] as? Date
        )
        #expect(pushed.recordID.recordName == local.id.uuidString)
        #expect(pushed[ClipboardCloudMapping.Key.deletedAt] is Date)
        #expect(pushedVersion != local.modifiedAt)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[local.id]
                == pushedVersion)
    }

    @Test func firstBatchReceiptsSurviveASecondBatchFailure() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 50_000), forKey: watermarkKey)
        let store = FakeSyncableStore()
        store.items = (0..<250).map {
            makeTextItem(text: "retry-\($0)", modifiedAt: Double($0))
        }
        let database = FakeCloudKitDatabase()
        database.failedSaveCallIndices = [1]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected the second CloudKit batch failure to fail sync")
            return
        }
        #expect(database.savedBatches.map(\.count) == [100, 100])
        let receipts = try #require(
            try pushReceipts(defaults: defaults, containerID: containerID)
        )
        let acceptedRecordNames = Set(database.savedBatches[0].map(\.recordID.recordName))
        let failedRecordNames = Set(database.savedBatches[1].map(\.recordID.recordName))
        #expect(Set(receipts.keys.map(\.uuidString)) == acceptedRecordNames)
        #expect(receipts.keys.allSatisfy { !failedRecordNames.contains($0.uuidString) })
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func unpreparableItemIsSkippedAndReplaysAfterBlobRestoration() async throws {
        let filename = "\(UUID().uuidString).txt"
        let item = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 10_000), forKey: watermarkKey)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [item]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let skippedResult = await service.start()

        #expect(skippedResult == .started)
        #expect(database.savedBatches.isEmpty)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID) == [:])

        let restoredBlobURL = try writeAsset("restored")
        defer { try? FileManager.default.removeItem(at: restoredBlobURL) }
        store.blobURLs[blob] = restoredBlobURL
        let retryResult = await service.start()

        #expect(retryResult == .started)
        #expect(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName)
                == [item.id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func unpreparableItemDoesNotBlockAHealthyItemInTheSameSet() async throws {
        let valid = makeTextItem(text: "valid", modifiedAt: 100)
        let filename = "\(UUID().uuidString).txt"
        let invalid = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 200)
        let blob = try #require(SyncBlobReference(filename: filename, kind: .text))
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 10_000), forKey: watermarkKey)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [valid, invalid]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let partialResult = await service.start()

        #expect(partialResult == .started)
        #expect(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName)
                == [valid.id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)
                == [valid.id: valid.modifiedAt])
        #expect(defaults.object(forKey: watermarkKey) == nil)

        let restoredBlobURL = try writeAsset("restored")
        defer { try? FileManager.default.removeItem(at: restoredBlobURL) }
        store.blobURLs[blob] = restoredBlobURL
        let retryResult = await service.start()

        #expect(retryResult == .started)
        #expect(database.savedBatches.count == 2)
        #expect(database.savedBatches[1].map(\.recordID.recordName) == [invalid.id.uuidString])
        let receipts = try #require(
            try pushReceipts(defaults: defaults, containerID: containerID)
        )
        #expect(receipts[valid.id] == valid.modifiedAt)
        #expect(receipts[invalid.id] == invalid.modifiedAt)
    }

    // MARK: - Push retry

    @Test func failedScheduledPushRetriesUntilItSucceeds() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            pushDebounceNanoseconds: 0,
            pushRetryDelaysNanoseconds: [0, 0, 0]
        )
        #expect(await service.start() == .started)

        let item = makeTextItem(text: "retry-until-accepted", modifiedAt: 100)
        database.failedSaveCallIndices = [0]
        store.items = [item]
        NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: store)
        while database.savedBatches.count < 2 {
            await Task.yield()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(database.savedBatches.count == 2)
        #expect(database.savedBatches.allSatisfy {
            $0.map(\.recordID.recordName) == [item.id.uuidString]
        })
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
        guard case .healthy = store.syncStatus else {
            Issue.record("Expected the successful retry to report a healthy sync")
            return
        }
    }

    @Test func scheduledPushRetriesStopAfterTheBoundedChain() async throws {
        let item = makeTextItem(text: "never-accepted", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let database = FakeCloudKitDatabase()
        database.failedSaveRecordNames = [item.id.uuidString]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            pushDebounceNanoseconds: 0,
            pushRetryDelaysNanoseconds: [0, 0, 0]
        )
        #expect(await service.start() == .started)

        store.items = [item]
        NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: store)
        while database.savedBatches.count < 4 {
            await Task.yield()
        }
        for _ in 0..<50 {
            await Task.yield()
        }

        #expect(database.savedBatches.count == 4)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID) == [:])
        guard case .failed = store.syncStatus else {
            Issue.record("Expected the exhausted retry chain to leave sync failed")
            return
        }
    }

    @Test func pushRetryDelayHonorsCloudKitRetryAfterSeconds() {
        let fallback: UInt64 = 5_000_000_000

        #expect(CloudKitSyncService.pushRetryDelayNanoseconds(
            for: rateLimitedError(retryAfterSeconds: 12),
            fallback: fallback
        ) == 12_000_000_000)
        #expect(CloudKitSyncService.pushRetryDelayNanoseconds(
            for: TestError.boom,
            fallback: fallback
        ) == fallback)
        #expect(CloudKitSyncService.pushRetryDelayNanoseconds(
            for: rateLimitedError(retryAfterSeconds: -1),
            fallback: fallback
        ) == fallback)
        #expect(CloudKitSyncService.pushRetryDelayNanoseconds(
            for: rateLimitedError(retryAfterSeconds: .greatestFiniteMagnitude),
            fallback: fallback
        ) == 3_600_000_000_000)
    }

    @Test func pushChunksTwoHundredFiftyRecordsIntoStableGroupsOf100() async throws {
        let store = FakeSyncableStore()
        store.items = (0..<250).map {
            makeTextItem(text: "item-\($0)", modifiedAt: Double(1_000 + $0))
        }
        let database = FakeCloudKitDatabase()
        let service = makeService(database: database, store: store)

        let result = await service.start()

        #expect(result == .started)
        #expect(database.savedBatches.map(\.count) == [100, 100, 50])
    }

    @Test func emptyCanonicalSetCompletesReceiptMigration() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 1_000), forKey: watermarkKey)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(database.savedBatches.isEmpty)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID) == [:])
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func migrationPullsBeforeReplayingTheReconciledCanonicalVersion() async throws {
        let id = UUID()
        let local = makeTextItem(id: id, text: "local-old", modifiedAt: 100)
        let remote = makeTextItem(id: id, text: "remote-new", modifiedAt: 200)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Date(timeIntervalSinceReferenceDate: 10_000), forKey: watermarkKey)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [local]
        store.onApplyReconciledDurably = {
            #expect(database.savedBatches.isEmpty)
            #expect(defaults.object(forKey: watermarkKey) != nil)
        }
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let pushed = try #require(database.savedBatches.flatMap { $0 }.first)
        #expect(pushed[ClipboardCloudMapping.Key.textContent] as? String == "remote-new")
        #expect(pushed[ClipboardCloudMapping.Key.modifiedAt] as? Date == remote.modifiedAt)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[id]
                == remote.modifiedAt)
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func saveBeforeReceiptCrashKeepsLegacySignalAndReplaysIdempotently() async throws {
        let item = makeTextItem(text: "replay-me", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        let legacyWatermark = Date(timeIntervalSinceReferenceDate: 10_000)
        defaults.set(legacyWatermark, forKey: watermarkKey)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [item]
        let crashingService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            beforeReceiptPersistence: {
                #expect(defaults.object(forKey: watermarkKey) as? Date == legacyWatermark)
                throw TestError.boom
            }
        )

        let firstResult = await crashingService.start()

        guard case .failed = firstResult else {
            Issue.record("Expected simulated post-save receipt crash")
            return
        }
        #expect(database.savedBatches.count == 1)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID) == nil)
        #expect(defaults.object(forKey: watermarkKey) as? Date == legacyWatermark)

        let retryingService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )
        let retryResult = await retryingService.start()

        #expect(retryResult == .started)
        #expect(database.savedBatches.count == 2)
        #expect(database.savedBatches.allSatisfy {
            $0.map(\.recordID.recordName) == [item.id.uuidString]
        })
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func corruptOrUnknownReceiptEnvelopeTriggersSafeFullReplay() async throws {
        let item = makeTextItem(text: "recover-corrupt-state", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        defaults.set(
            Data(#"{"version":999,"receipts":{}}"#.utf8),
            forKey: pushReceiptsKey(containerID)
        )
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [item]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName)
                == [item.id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func receiptStateIsIsolatedByCloudKitContainer() async throws {
        let item = makeTextItem(text: "container-scoped", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let firstContainerID = "test.first.\(UUID().uuidString)"
        let secondContainerID = "test.second.\(UUID().uuidString)"
        try setPushReceipts(
            [item.id: item.modifiedAt],
            defaults: defaults,
            containerID: firstContainerID
        )
        let firstDatabase = FakeCloudKitDatabase()
        let firstStore = FakeSyncableStore()
        firstStore.items = [item]
        let secondDatabase = FakeCloudKitDatabase()
        let secondStore = FakeSyncableStore()
        secondStore.items = [item]

        let firstResult = await CloudKitSyncService(
            containerIdentifier: firstContainerID,
            store: firstStore,
            database: firstDatabase,
            defaults: defaults
        ).start()
        let secondResult = await CloudKitSyncService(
            containerIdentifier: secondContainerID,
            store: secondStore,
            database: secondDatabase,
            defaults: defaults
        ).start()

        #expect(firstResult == .started)
        #expect(secondResult == .started)
        #expect(firstDatabase.savedBatches.isEmpty)
        #expect(secondDatabase.savedBatches.flatMap { $0 }.count == 1)
        #expect(try pushReceipts(defaults: defaults, containerID: firstContainerID)?[item.id]
                == item.modifiedAt)
        #expect(try pushReceipts(defaults: defaults, containerID: secondContainerID)?[item.id]
                == item.modifiedAt)
    }

    @Test func receiptCommitRechecksCanonicalIDsAfterSuspendedSave() async throws {
        let id = UUID()
        let original = makeTextItem(id: id, text: "prepared", modifiedAt: 100)
        let updated = makeTextItem(id: id, text: "changed-during-save", modifiedAt: 200)
        let removed = makeTextItem(text: "removed-during-save", modifiedAt: 150)
        let reintroduced = makeTextItem(text: "reintroduced-during-save", modifiedAt: 125)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts(
            [reintroduced.id: reintroduced.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [original, removed]
        database.onSaveRecords = { _ in
            await Task.yield()
            store.items = [updated, reintroduced]
        }
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let firstResult = await service.start()

        #expect(firstResult == .started)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[id]
                == original.modifiedAt)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[removed.id]
                == nil)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[reintroduced.id]
                == reintroduced.modifiedAt)

        database.onSaveRecords = nil
        let retryService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )
        let retryResult = await retryService.start()

        #expect(retryResult == .started)
        #expect(database.savedBatches.count == 2)
        #expect(database.savedBatches[0].count == 2)
        #expect(database.savedBatches[1].count == 1)
        #expect(database.savedBatches[1].first?[ClipboardCloudMapping.Key.modifiedAt] as? Date
                == updated.modifiedAt)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[id]
                == updated.modifiedAt)
    }

    @Test func overlappingPushRequestsSerializeAroundOneReceiptCommit() async {
        let item = makeTextItem(text: "serialize", modifiedAt: 100)
        let database = FakeCloudKitDatabase()
        database.onSaveRecords = { _ in
            await Task.yield()
        }
        let store = FakeSyncableStore()
        store.items = [item]
        let service = makeService(database: database, store: store)

        async let first = service.start()
        async let second = service.start()
        let results = await [first, second]

        #expect(results.allSatisfy { $0 == .started })
        #expect(database.savedBatches.count == 1)
        #expect(database.savedBatches.first?.map(\.recordID.recordName)
                == [item.id.uuidString])
    }

    @Test func repairInvalidationDrainsSuspendedPushAndQueuedFollowUpBeforeCommitting() async throws {
        let repairFilename = "\(UUID().uuidString).txt"
        let repairItem = makeLargeTextItem(id: UUID(), filename: repairFilename, modifiedAt: 100)
        let repairBlob = try #require(SyncBlobReference(filename: repairFilename, kind: .text))
        let localURL = try writeAsset("ordered-repair")
        defer { try? FileManager.default.removeItem(at: localURL) }
        let unrelated = makeTextItem(text: "unrelated-dirty-record", modifiedAt: 200)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts(
            [repairItem.id: repairItem.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(moreComing: false),
            page(moreComing: false),
            page(changed: [try record(for: repairItem)], moreComing: false)
        ]
        let firstSaveGate = AsyncTestGate()
        database.onSaveRecords = { _ in
            await firstSaveGate.waitOnce()
        }
        let store = FakeSyncableStore()
        store.items = [repairItem, unrelated]
        store.blobURLs[repairBlob] = localURL
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let initialStart = Task { await service.start() }
        while !firstSaveGate.hasWaiter {
            await Task.yield()
        }
        let queuedStart = Task { await service.start() }
        while database.fetchCount < 2 {
            await Task.yield()
        }
        let repairPull = Task { await service.handleRemoteChange() }
        while database.fetchCount < 3 {
            await Task.yield()
        }
        firstSaveGate.resume()

        let initialResult = await initialStart.value
        let queuedResult = await queuedStart.value
        let repairResult = await repairPull.value

        #expect(initialResult == .started)
        #expect(queuedResult == .started)
        #expect(repairResult)
        #expect(database.savedBatches.count == 2)
        #expect(database.savedBatches[0].map(\.recordID.recordName) == [unrelated.id.uuidString])
        #expect(database.savedBatches[1].map(\.recordID.recordName) == [repairItem.id.uuidString])
        #expect(database.savedBatches[1].first?[ClipboardCloudMapping.Key.blob] is CKAsset)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[repairItem.id]
                == repairItem.modifiedAt)
    }

    // MARK: - Lifecycle invalidation

    @Test func stopDuringPullRejectsALatePageBeforeReconciliationOrCheckpointMutation() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let local = makeTextItem(text: "local", modifiedAt: 100)
        let remote = makeTextItem(text: "late-remote", modifiedAt: 200)
        try setPushReceipts(
            [local.id: local.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let fetchGate = AsyncTestGate()
        let database = FakeCloudKitDatabase()
        database.onFetchZoneChanges = {
            await fetchGate.waitOnce()
        }
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        store.items = [local]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let startTask = Task { await service.start() }
        while !fetchGate.hasWaiter {
            await Task.yield()
        }
        service.stop()
        store.markSyncUnavailable(reason: .disabled)
        fetchGate.resume()
        _ = await startTask.value

        #expect(store.appliedReconciled == nil)
        #expect(store.syncStatus == .localOnly(reason: .disabled))
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)
                == [local.id: local.modifiedAt])
        #expect(database.savedBatches.isEmpty)
    }

    @Test func stopDuringBlobWriteRemovesStagingAndRejectsAllLateState() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let filename = "\(UUID().uuidString).txt"
        let remote = makeLargeTextItem(id: UUID(), filename: filename, modifiedAt: 100)
        let destination = try #require(SyncBlobReference(filename: filename, kind: .text))
        let assetURL = try writeAsset("late remote blob")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let writeGate = AsyncTestGate()
        let database = FakeCloudKitDatabase()
        database.pages = [
            page(changed: [try record(for: remote, blobURL: assetURL)], moreComing: false)
        ]
        let store = FakeSyncableStore()
        store.onWriteBlob = { _ in
            await writeGate.waitOnce()
        }
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let startTask = Task { await service.start() }
        while !writeGate.hasWaiter {
            await Task.yield()
        }
        service.stop()
        store.markSyncUnavailable(reason: .disabled)
        writeGate.resume()
        _ = await startTask.value

        let staged = try #require(store.writtenBlobs.first)
        #expect(staged != destination)
        #expect(store.deletedBlobs == [staged])
        #expect(store.blobURL(for: staged).map {
            FileManager.default.fileExists(atPath: $0.path)
        } == false)
        #expect(store.blobURL(for: destination).map {
            FileManager.default.fileExists(atPath: $0.path)
        } == false)
        #expect(store.appliedReconciled == nil)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
        #expect(store.syncStatus == .localOnly(reason: .disabled))
        #expect(database.savedBatches.isEmpty)
    }

    @Test func stopDuringSaveLeavesReceiptsRetryableAndDoesNotReportHealthy() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        let legacyWatermark = Date(timeIntervalSinceReferenceDate: 10_000)
        defaults.set(legacyWatermark, forKey: watermarkKey)
        let local = makeTextItem(text: "save-in-flight", modifiedAt: 100)
        let saveGate = AsyncTestGate()
        let database = FakeCloudKitDatabase()
        database.onSaveRecords = { _ in
            await saveGate.waitOnce()
        }
        let store = FakeSyncableStore()
        store.items = [local]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            pushDebounceNanoseconds: 0
        )

        let startTask = Task { await service.start() }
        while !saveGate.hasWaiter {
            await Task.yield()
        }
        service.stop()
        store.markSyncUnavailable(reason: .disabled)
        saveGate.resume()
        _ = await startTask.value

        #expect(database.savedBatches.count == 1)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID) == nil)
        #expect(defaults.object(forKey: watermarkKey) as? Date == legacyWatermark)
        #expect(store.syncStatus == .localOnly(reason: .disabled))

        store.items = [makeTextItem(text: "after-stop", modifiedAt: 200)]
        NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: store)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(database.savedBatches.count == 1)
    }

    @Test func stopIsIdempotentAndUnregistersTheLocalChangeObserver() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        try setPushReceipts([:], defaults: defaults, containerID: containerID)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            pushDebounceNanoseconds: 0
        )
        #expect(await service.start() == .started)

        service.stop()
        service.stop()
        store.markSyncUnavailable(reason: .disabled)
        store.items = [makeTextItem(text: "after-stop", modifiedAt: 100)]
        NotificationCenter.default.post(name: .yankLocalStoreDidChange, object: store)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(database.savedBatches.isEmpty)
        #expect(store.syncStatus == .localOnly(reason: .disabled))
    }

    // MARK: - Historical backfill

    @Test func backfillUploadsOnlyMissingUUIDRecordsWithoutMutatingPushCheckpoints() async throws {
        let existing = makeTextItem(text: "existing", modifiedAt: 100)
        let firstMissing = makeTextItem(text: "first-missing", modifiedAt: 200)
        let secondMissing = makeTextItem(text: "second-missing", modifiedAt: 300)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        let existingWatermark = Date(timeIntervalSinceReferenceDate: 1_000)
        defaults.set(existingWatermark, forKey: watermarkKey)
        let existingReceipts = [existing.id: Date(timeIntervalSinceReferenceDate: 50)]
        try setPushReceipts(
            existingReceipts,
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.existingRecordNames = [existing.id.uuidString]
        let store = FakeSyncableStore()
        store.items = [existing, firstMissing, secondMissing]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = try await service.backfillMissingLocalRecords()

        #expect(result.localRecordCount == 3)
        #expect(result.presentRecordCountBefore == 1)
        #expect(result.missingRecordCountBefore == 2)
        #expect(result.uploadedRecordCount == 2)
        #expect(result.presentRecordCountAfter == 3)
        #expect(result.converged)
        #expect(Set(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName))
                == [firstMissing.id.uuidString, secondMissing.id.uuidString])
        #expect(defaults.object(forKey: watermarkKey) as? Date == existingWatermark)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)
                == existingReceipts)
    }

    @Test func backfillDryRunAndRepeatedExecutionAreIdempotent() async throws {
        let item = makeTextItem(text: "missing", modifiedAt: 100)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [item]
        let service = makeService(database: database, store: store)

        let preview = try await service.backfillMissingLocalRecords(dryRun: true)
        #expect(preview.missingRecordCountBefore == 1)
        #expect(preview.uploadedRecordCount == 0)
        #expect(database.savedBatches.isEmpty)

        let first = try await service.backfillMissingLocalRecords()
        let second = try await service.backfillMissingLocalRecords()

        #expect(first.uploadedRecordCount == 1)
        #expect(second.missingRecordCountBefore == 0)
        #expect(second.uploadedRecordCount == 0)
        #expect(database.savedBatches.count == 1)
    }

    @Test func backfillRefusesAllWritesWhenAMissingRecordHasNoLocalBlob() async throws {
        let missingBlobItem = makeLargeTextItem(
            id: UUID(),
            filename: "\(UUID().uuidString).txt",
            modifiedAt: 100
        )
        let validItem = makeTextItem(text: "valid", modifiedAt: 200)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = [missingBlobItem, validItem]
        let service = makeService(database: database, store: store)

        await #expect(throws: (any Error).self) {
            try await service.backfillMissingLocalRecords()
        }
        #expect(database.savedBatches.isEmpty)
    }

    @Test func backfillPartialSaveFailsWithoutMutatingPushCheckpoints() async throws {
        let item = makeTextItem(text: "retry-me", modifiedAt: 100)
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        let existingWatermark = Date(timeIntervalSinceReferenceDate: 1_000)
        defaults.set(existingWatermark, forKey: watermarkKey)
        let existingReceipts = [item.id: Date(timeIntervalSinceReferenceDate: 50)]
        try setPushReceipts(
            existingReceipts,
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.failedSaveRecordNames = [item.id.uuidString]
        let store = FakeSyncableStore()
        store.items = [item]
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        await #expect(throws: (any Error).self) {
            try await service.backfillMissingLocalRecords()
        }
        #expect(database.existingRecordNames.isEmpty)
        #expect(defaults.object(forKey: watermarkKey) as? Date == existingWatermark)
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)
                == existingReceipts)
    }

    @Test func backfillChunksPresenceChecksAndUploadsIntoGroupsOf100() async throws {
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        store.items = (0..<150).map {
            makeTextItem(text: "missing-\($0)", modifiedAt: Double($0))
        }
        let service = makeService(database: database, store: store)

        let result = try await service.backfillMissingLocalRecords()

        #expect(result.uploadedRecordCount == 150)
        #expect(database.presenceBatchSizes == [100, 50, 100, 50])
        #expect(database.savedBatches.map(\.count) == [100, 50])
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

    @Test func pullDoesNotAdvanceTokenWhenDurableStoreApplyFails() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let remote = makeTextItem(text: "cannot-persist", modifiedAt: 500)
        let database = FakeCloudKitDatabase()
        database.pages = [page(changed: [try record(for: remote)], moreComing: false)]
        let store = FakeSyncableStore()
        store.durableApplyError = TestError.boom
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected a durable local apply failure to fail sync")
            return
        }
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
    }

    @Test func startRetriesFromScratchAndReuploadsLocalItemsWhenChangeTokenExpired() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let watermarkKey = "cloudkit.lastPushedModifiedAt.\(containerID)"
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: tokenKey)
        defaults.set(Date(timeIntervalSinceReferenceDate: 1_000), forKey: watermarkKey)
        let local = makeTextItem(text: "local-only", modifiedAt: 100)
        try setPushReceipts(
            [local.id: local.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
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
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[local.id]
                == local.modifiedAt)
        #expect(defaults.object(forKey: watermarkKey) == nil)
    }

    @Test func tokenExpiryInterruptionLeavesReceiptsInvalidatedForRecreatedReplay() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let tokenKey = "cloudkit.changeToken.\(containerID)"
        let staleTokenData = Data([0x01, 0x02, 0x03])
        defaults.set(staleTokenData, forKey: tokenKey)
        let local = makeTextItem(text: "replay-after-checkpoint-crash", modifiedAt: 100)
        try setPushReceipts(
            [local.id: local.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
        let database = FakeCloudKitDatabase()
        database.fetchErrors = [expiredChangeTokenError()]
        let store = FakeSyncableStore()
        store.items = [local]
        let interruptedService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults,
            afterReceiptInvalidationBeforeTokenPersistence: {
                #expect(defaults.data(forKey: pushReceiptsKey(containerID)) == nil)
                #expect(defaults.data(forKey: tokenKey) == staleTokenData)
                throw TestError.boom
            }
        )

        let interruptedResult = await interruptedService.start()

        guard case .failed = interruptedResult else {
            Issue.record("Expected interruption between receipt and token checkpoints")
            return
        }
        #expect(defaults.data(forKey: pushReceiptsKey(containerID)) == nil)
        #expect(defaults.data(forKey: tokenKey) == staleTokenData)
        #expect(database.savedBatches.isEmpty)

        database.fetchErrors = [expiredChangeTokenError()]
        let recreatedService = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            defaults: defaults
        )
        let replayResult = await recreatedService.start()

        #expect(replayResult == .started)
        #expect(database.savedBatches.flatMap { $0 }.map(\.recordID.recordName)
                == [local.id.uuidString])
        #expect(try pushReceipts(defaults: defaults, containerID: containerID)?[local.id]
                == local.modifiedAt)
        #expect(defaults.data(forKey: tokenKey) == nil)
    }

    @Test func remoteChangeReuploadsLocalItemsWhenChangeTokenExpired() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let local = makeTextItem(text: "local-after-remote-token-reset", modifiedAt: 100)
        try setPushReceipts(
            [local.id: local.modifiedAt],
            defaults: defaults,
            containerID: containerID
        )
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

    // MARK: - Synced settings: resolution rule

    @Test func resolutionAdoptsAStrictlyNewerRemoteValue() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.essential, 100),
            remote: RemoteSettingsRecord(settings: settings(.deep, 200), updatedAt: stamp(200))
        )

        #expect(decision == .adopt(settings(.deep, 200)))
    }

    @Test func resolutionKeepsTheIncumbentWhenTheStampsTie() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.unlimited, 200),
            remote: RemoteSettingsRecord(settings: settings(.essential, 200), updatedAt: stamp(200))
        )

        #expect(decision == .idle)
    }

    @Test func resolutionPublishesOverAStrictlyOlderRemoteValue() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.unlimited, 900),
            remote: RemoteSettingsRecord(settings: settings(.essential, 200), updatedAt: stamp(200))
        )

        #expect(decision == .publish)
    }

    /// A tier this build cannot read is almost certainly a newer client's. Its stamp still
    /// defends the slot, so an older local choice must not stomp on it.
    @Test func resolutionBacksOffFromAnUnreadableRemoteValueWithANewerStamp() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.essential, 100),
            remote: RemoteSettingsRecord(settings: nil, updatedAt: stamp(900))
        )

        #expect(decision == .idle)
    }

    @Test func resolutionBacksOffFromAnUnreadableRemoteValueWithATiedStamp() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.essential, 500),
            remote: RemoteSettingsRecord(settings: nil, updatedAt: stamp(500))
        )

        #expect(decision == .idle)
    }

    /// Repair is still possible: a genuinely newer local choice may overwrite a record this
    /// build cannot read, so a corrupt value is not permanent.
    @Test func resolutionRepairsAnUnreadableRemoteValueWithAnOlderStamp() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.deep, 900),
            remote: RemoteSettingsRecord(settings: nil, updatedAt: stamp(100))
        )

        #expect(decision == .publish)
    }

    @Test func resolutionNeverPublishesALimitTheUserNeverChose() {
        let unchosen = SyncedSettings(historyLimit: .essential, updatedAt: .distantPast)

        #expect(CloudKitSyncService.settingsResolution(local: unchosen, remote: nil) == .idle)
        #expect(
            CloudKitSyncService.settingsResolution(
                local: unchosen,
                remote: RemoteSettingsRecord(settings: nil, updatedAt: .distantPast)
            ) == .idle
        )
    }

    @Test func resolutionPublishesAChosenLimitWhenTheZoneHasNoRecord() {
        let decision = CloudKitSyncService.settingsResolution(
            local: settings(.deep, 500),
            remote: nil
        )

        #expect(decision == .publish)
    }

    // MARK: - Synced settings: pull

    @Test func pullAdoptsAStrictlyNewerRemoteHistoryLimit() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: 100)
        let database = FakeCloudKitDatabase()
        let remoteSettings = settingsRecord(rawLimit: 500, updatedAt: 200)
        database.seedSettingsRecord(remoteSettings)
        database.pages = [page(changed: [remoteSettings], moreComing: false)]
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(settingsStore.applied.count == 1)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
        #expect(
            settingsStore.syncedSettings?.updatedAt == Date(timeIntervalSinceReferenceDate: 200)
        )
        // The adopted value already matches the server, so reconcile writes nothing back.
        #expect(database.conditionalSaves.isEmpty)
    }

    @Test func pullKeepsTheLocalHistoryLimitWhenTheRemoteStampIsOlder() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .deep, updatedAt: 300)
        let database = FakeCloudKitDatabase()
        let remoteSettings = settingsRecord(rawLimit: 100, updatedAt: 200)
        database.seedSettingsRecord(remoteSettings)
        database.pages = [page(changed: [remoteSettings], moreComing: false)]
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        _ = await service.start()

        #expect(settingsStore.applied.isEmpty)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
        // The newer local choice replaces the stale remote one.
        #expect(remoteLimit(of: database.settingsRecord) == 500)
    }

    @Test func pullKeepsTheIncumbentHistoryLimitWhenTheStampsTie() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .deep, updatedAt: 200)
        let database = FakeCloudKitDatabase()
        let remoteSettings = settingsRecord(rawLimit: 100, updatedAt: 200)
        database.seedSettingsRecord(remoteSettings)
        database.pages = [page(changed: [remoteSettings], moreComing: false)]
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        _ = await service.start()

        #expect(settingsStore.applied.isEmpty)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
        // Neither side moves, so the two devices stop trading writes.
        #expect(database.conditionalSaves.isEmpty)
        #expect(remoteLimit(of: database.settingsRecord) == 100)
    }

    @Test func pullRejectsAMalformedRemoteHistoryLimitWithoutBreakingTheClipPull() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let clip = makeTextItem(text: "still-syncs", modifiedAt: 500)
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: 100)
        let database = FakeCloudKitDatabase()
        let remoteSettings = settingsRecord(rawLimit: 777, updatedAt: 900)
        database.seedSettingsRecord(remoteSettings)
        database.pages = [page(
            changed: [remoteSettings, try record(for: clip)],
            moreComing: false
        )]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            settingsStore: settingsStore,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        let applied = try #require(store.appliedReconciled)
        #expect(applied.contains { $0.id == clip.id })
        #expect(settingsStore.applied.isEmpty)
        #expect(settingsStore.syncedSettings?.historyLimit == .essential)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID).isEmpty)
        // Its stamp is newer, so the unreadable value is left strictly alone.
        #expect(database.conditionalSaves.isEmpty)
        #expect(remoteLimit(of: database.settingsRecord) == 777)
    }

    @Test func pullNeverQuarantinesASettingsRecord() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: 100)
        let database = FakeCloudKitDatabase()
        // No fields at all: the record is unreadable, which is the case that would otherwise
        // land in the quarantine as an unmappable clip.
        let unreadable = CKRecord(
            recordType: SyncedSettingsCloudMapping.recordType,
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        database.seedSettingsRecord(unreadable)
        database.pages = [page(changed: [unreadable], moreComing: false)]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            settingsStore: settingsStore,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(settingsStore.applied.isEmpty)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID).isEmpty)
    }

    /// The upgrade path for finding 4: a build that cannot read the record ignores it and lets
    /// the token advance past it, and the build that *can* read it still adopts it — because
    /// bring-up fetches the record by ID rather than relying on the change feed.
    @Test func anUnreadableSettingsRecordIsAdoptedByALaterBuildAfterTheTokenMovedOn() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: 100)
        let database = FakeCloudKitDatabase()
        let unreadableSettings = settingsRecord(rawLimit: 777, updatedAt: 900)
        database.seedSettingsRecord(unreadableSettings)
        database.pages = [page(changed: [unreadableSettings], moreComing: false)]
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            settingsStore: settingsStore,
            defaults: defaults
        )

        #expect(await service.start() == .started)
        #expect(settingsStore.applied.isEmpty)
        service.stop()

        // The tier becomes known (a later build), and the change feed is already drained.
        database.pages = []
        database.seedSettingsRecord(settingsRecord(rawLimit: 500, updatedAt: 900))
        let upgraded = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            settingsStore: settingsStore,
            defaults: defaults
        )

        #expect(await upgraded.start() == .started)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
    }

    @Test func pullClearsASettingsRecordQuarantinedByAnEarlierBuild() async throws {
        let defaults = isolatedDefaults()
        let containerID = "test.\(UUID().uuidString)"
        defaults.set(
            try CloudKitPullQuarantineCodec.encode([
                SyncedSettingsCloudMapping.recordName: CloudKitPullQuarantineEntry(
                    reason: "Record fields cannot be read as a clip.",
                    attemptCount: 2
                )
            ]),
            forKey: pullQuarantineKey(containerID)
        )
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: 100)
        let database = FakeCloudKitDatabase()
        database.seedSettingsRecord(settingsRecord(rawLimit: 500, updatedAt: 400))
        let store = FakeSyncableStore()
        let service = CloudKitSyncService(
            containerIdentifier: containerID,
            store: store,
            database: database,
            settingsStore: settingsStore,
            defaults: defaults
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
        #expect(try pullQuarantine(defaults: defaults, containerID: containerID).isEmpty)
    }

    @Test func replayingTheSameSettingsRecordIsANoOp() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: 100)
        let database = FakeCloudKitDatabase()
        let remote = settingsRecord(rawLimit: 500, updatedAt: 200)
        database.seedSettingsRecord(remote)
        database.pages = [
            page(changed: [remote], moreComing: false),
            page(changed: [remote], moreComing: false)
        ]
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        _ = await service.start()
        _ = await service.handleRemoteChange()

        #expect(settingsStore.applied.count == 1)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
        #expect(database.conditionalSaves.isEmpty)
    }

    // MARK: - Synced settings: publish

    /// Finding 6: publishing costs one read and one write. No guaranteed conflict dance.
    @Test func publishingAChosenLimitTakesOneFetchAndOneSave() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .deep, updatedAt: 500)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        _ = await service.start()

        #expect(database.settingsFetchCount == 1)
        #expect(database.conditionalSaves.count == 1)
        #expect(remoteLimit(of: database.settingsRecord) == 500)

        // Reconciling again finds its own value on the server and writes nothing.
        _ = await service.start()

        #expect(database.conditionalSaves.count == 1)
    }

    @Test func publishingOverAnOlderRemoteRecordReusesTheFetchedInstance() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .unlimited, updatedAt: 900)
        let database = FakeCloudKitDatabase()
        database.seedSettingsRecord(settingsRecord(rawLimit: 100, updatedAt: 200))
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(settingsStore.applied.isEmpty)
        #expect(database.conditionalSaves.count == 1)
        #expect(remoteLimit(of: database.settingsRecord) == 1_000)
    }

    @Test func publishingIsSkippedForALimitTheUserNeverChose() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .essential, updatedAt: nil)
        let database = FakeCloudKitDatabase()
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        _ = await service.start()

        #expect(database.conditionalSaves.isEmpty)
        #expect(database.settingsRecord == nil)
    }

    /// Finding 5: losing the race is a resolution, not a failure — the newer value simply wins.
    @Test func aConcurrentChangeMidSaveConvergesWithoutFailingSync() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .unlimited, updatedAt: 300)
        let database = FakeCloudKitDatabase()
        database.seedSettingsRecord(settingsRecord(rawLimit: 100, updatedAt: 200))
        database.forcedConditionalSaveConflicts = 1
        // Another device lands a newer choice in the window between our fetch and our save.
        let newerRemote = settingsRecord(rawLimit: 500, updatedAt: 800)
        database.onConditionalSave = { [weak database] _ in
            database?.seedSettingsRecord(newerRemote)
        }
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(store.syncStatus.isHealthy)
        #expect(settingsStore.syncedSettings?.historyLimit == .deep)
        #expect(remoteLimit(of: database.settingsRecord) == 500)
    }

    @Test func repeatedlyLosingTheSettingsRaceLeavesSyncHealthy() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .unlimited, updatedAt: 900)
        let database = FakeCloudKitDatabase()
        database.seedSettingsRecord(settingsRecord(rawLimit: 100, updatedAt: 200))
        database.forcedConditionalSaveConflicts = 5
        let store = FakeSyncableStore()
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        let result = await service.start()

        #expect(result == .started)
        #expect(store.syncStatus.isHealthy)
        // Bounded: it gives up for this pass instead of spinning.
        #expect(database.conditionalSaves.count == 2)
    }

    /// Finding 3: the two halves of a push are independent.
    @Test func settingsStillPublishWhenTheClipPushFails() async throws {
        let settingsStore = FakeSyncedSettingsStore(historyLimit: .deep, updatedAt: 500)
        let database = FakeCloudKitDatabase()
        database.failedSaveCallIndices = [0]
        let store = FakeSyncableStore()
        store.items = [makeTextItem(text: "cannot-land", modifiedAt: 100)]
        let service = makeService(
            database: database,
            store: store,
            settingsStore: settingsStore
        )

        let result = await service.start()

        guard case .failed = result else {
            Issue.record("Expected the failing clip batch to surface as a sync failure")
            return
        }
        // The clip failure is reported, but the limit still reached CloudKit.
        #expect(database.conditionalSaves.count == 1)
        #expect(remoteLimit(of: database.settingsRecord) == 500)
    }

    // MARK: - Helpers

    private func makeService(
        database: any CloudKitDatabase,
        store: SyncableStore,
        settingsStore: (any SyncedSettingsStore)? = nil
    ) -> CloudKitSyncService {
        CloudKitSyncService(
            containerIdentifier: "test.\(UUID().uuidString)",
            store: store,
            database: database,
            settingsStore: settingsStore,
            defaults: isolatedDefaults()
        )
    }

    private func settingsRecord(rawLimit: Int, updatedAt: TimeInterval) -> CKRecord {
        let record = CKRecord(
            recordType: SyncedSettingsCloudMapping.recordType,
            recordID: SyncedSettingsCloudMapping.recordID(in: zoneID)
        )
        record[SyncedSettingsCloudMapping.Key.historyLimit] = rawLimit
        record[SyncedSettingsCloudMapping.Key.updatedAt] =
            Date(timeIntervalSinceReferenceDate: updatedAt)
        return record
    }

    private func remoteLimit(of record: CKRecord?) -> Int? {
        record?[SyncedSettingsCloudMapping.Key.historyLimit] as? Int
    }

    private func stamp(_ secondsSinceReferenceDate: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: secondsSinceReferenceDate)
    }

    private func settings(
        _ historyLimit: HistoryLimit,
        _ secondsSinceReferenceDate: TimeInterval
    ) -> SyncedSettings {
        SyncedSettings(
            historyLimit: historyLimit,
            updatedAt: stamp(secondsSinceReferenceDate)
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CloudKitSyncServiceTests.\(UUID().uuidString)")!
    }

    private func makeTextItem(
        id: UUID = UUID(),
        text: String,
        modifiedAt: TimeInterval
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: modifiedAt),
            textContent: text,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt)
        )
    }

    private func pushReceiptsKey(_ containerID: String) -> String {
        "cloudkit.pushReceipts.\(containerID)"
    }

    private func setPushReceipts(
        _ receipts: [UUID: Date],
        defaults: UserDefaults,
        containerID: String
    ) throws {
        defaults.set(
            try CloudKitPushReceiptCodec.encode(receipts),
            forKey: pushReceiptsKey(containerID)
        )
    }

    private func pushReceipts(
        defaults: UserDefaults,
        containerID: String
    ) throws -> [UUID: Date]? {
        guard let data = defaults.data(forKey: pushReceiptsKey(containerID)) else {
            return nil
        }
        return try CloudKitPushReceiptCodec.decode(data)
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

    private func rateLimitedError(retryAfterSeconds: Double) -> any Error {
        NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: retryAfterSeconds]
        )
    }

    private func page(
        changed: [CKRecord] = [],
        deletedNames: [String] = [],
        failedRecords: [CloudKitRecordFailure] = [],
        moreComing: Bool
    ) -> CloudKitZoneChanges {
        CloudKitZoneChanges(
            changedRecords: changed,
            deletedRecordNames: deletedNames,
            failedRecords: failedRecords,
            changeToken: nil,
            moreComing: moreComing
        )
    }

    private func retryableRecordFailure(
        _ recordName: String = UUID().uuidString
    ) -> CloudKitRecordFailure {
        CloudKitRecordFailure(
            recordName: recordName,
            error: NSError(
                domain: CKError.errorDomain,
                code: CKError.Code.networkFailure.rawValue
            )
        )
    }

    private func permanentRecordFailure(_ recordName: String) -> CloudKitRecordFailure {
        CloudKitRecordFailure(
            recordName: recordName,
            error: NSError(
                domain: CKError.errorDomain,
                code: CKError.Code.unknownItem.rawValue
            )
        )
    }

    private func pullQuarantineKey(_ containerID: String) -> String {
        "cloudkit.pullQuarantine.\(containerID)"
    }

    private func pullQuarantine(
        defaults: UserDefaults,
        containerID: String
    ) throws -> [String: CloudKitPullQuarantineEntry] {
        guard let data = defaults.data(forKey: pullQuarantineKey(containerID)) else { return [:] }
        return try CloudKitPullQuarantineCodec.decode(data)
    }
}

private enum TestError: Error { case boom }

private extension SyncStatus {
    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}

@MainActor
private final class AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasWaited = false

    var hasWaiter: Bool {
        continuation != nil
    }

    func waitOnce() async {
        guard !hasWaited else { return }
        hasWaited = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// In-memory `CloudKitDatabase`: returns the configured zone-change pages in order, records
/// every saved batch, and can be told to fail bring-up. `@MainActor` to match the seam.
@MainActor
private final class FakeCloudKitDatabase: CloudKitDatabase {
    var pages: [CloudKitZoneChanges] = []
    var existingRecordNames: Set<String> = []
    var ensureZoneError: (any Error)?
    var fetchErrors: [any Error] = []
    var saveError: (any Error)?
    var failedSaveRecordNames: [String] = []
    var failedSaveCallIndices: Set<Int> = []
    var fetchableRecords: [String: CKRecord] = [:]
    var permanentlyMissingFetchRecordNames: Set<String> = []
    var fetchRecordsError: (any Error)?
    var onFetchZoneChanges: (() async -> Void)?
    var onSaveRecords: (([CKRecord]) async -> Void)?
    /// Forces the next N conditional saves to report a conflict even when the change tag would
    /// have matched, standing in for a third device writing between the fetch and the save.
    var forcedConditionalSaveConflicts = 0
    /// Runs inside a conditional save, so a test can move the server's copy in the window
    /// between this device's fetch and its write.
    var onConditionalSave: ((CKRecord) -> Void)?

    private(set) var ensuredZone = false
    private(set) var ensuredSubscription = false
    private(set) var savedBatches: [[CKRecord]] = []
    private(set) var presenceBatchSizes: [Int] = []
    private(set) var fetchedRecordNameBatches: [[String]] = []
    private(set) var conditionalSaves: [CKRecord] = []
    private(set) var fetchCount = 0
    private var saveCallIndex = 0
    private var pageIndex = 0
    /// Server-side change counter per record, and the version each handed-out copy was read at.
    private var serverRecordVersions: [String: Int] = [:]
    private var fetchedRecordVersions: [ObjectIdentifier: Int] = [:]

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
        await onFetchZoneChanges?()
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

    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence {
        presenceBatchSizes.append(recordNames.count)
        let requested = Set(recordNames)
        return CloudKitRecordPresence(
            presentRecordNames: requested.intersection(existingRecordNames),
            missingRecordNames: requested.subtracting(existingRecordNames)
        )
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords {
        fetchedRecordNameBatches.append(recordNames)
        if let fetchRecordsError { throw fetchRecordsError }
        var fetched = CloudKitFetchedRecords()
        for recordName in recordNames {
            if permanentlyMissingFetchRecordNames.contains(recordName) {
                fetched.permanentlyMissingRecordNames.insert(recordName)
            } else if let record = fetchableRecords[recordName] {
                fetched.records.append(checkedOutCopy(of: record, named: recordName))
            }
        }
        return fetched
    }

    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult {
        if let saveError { throw saveError }
        let currentSaveCallIndex = saveCallIndex
        saveCallIndex += 1
        savedBatches.append(records)
        await onSaveRecords?(records)
        let failuresForCall = failedSaveCallIndices.contains(currentSaveCallIndex)
            ? records.map(\.recordID.recordName)
            : self.failedSaveRecordNames
        existingRecordNames.formUnion(
            records.compactMap {
                failuresForCall.contains($0.recordID.recordName) ? nil : $0.recordID.recordName
            }
        )
        return CloudKitRecordSaveResult(failedRecordNames: failuresForCall)
    }

    /// Models `.ifServerRecordUnchanged` with a change-tag surrogate: `fetchRecords` hands out a
    /// *copy* stamped with the server version it was read at, and a save is accepted only while
    /// that version is still current. Handing out the live object instead would let a caller's
    /// in-place edit mutate "the server" even when its save is rejected.
    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        conditionalSaves.append(record)
        if let saveError { throw saveError }
        onConditionalSave?(record)
        if forcedConditionalSaveConflicts > 0 {
            forcedConditionalSaveConflicts -= 1
            return .conflict
        }
        let recordName = record.recordID.recordName
        let presentedVersion = fetchedRecordVersions[ObjectIdentifier(record)]
        if fetchableRecords[recordName] != nil,
           presentedVersion != serverRecordVersions[recordName, default: 0] {
            // The server holds a copy this caller never read — a freshly minted record, or one
            // read before someone else wrote.
            return .conflict
        }
        storeServerRecord(record, named: recordName)
        return .saved
    }

    /// The zone's singleton settings record as the server holds it.
    var settingsRecord: CKRecord? {
        fetchableRecords[SyncedSettingsCloudMapping.recordName]
    }

    /// Publishes a record as if another device had written it, which invalidates any copy this
    /// device already read.
    func seedSettingsRecord(_ record: CKRecord) {
        storeServerRecord(record, named: SyncedSettingsCloudMapping.recordName)
    }

    private func storeServerRecord(_ record: CKRecord, named recordName: String) {
        fetchableRecords[recordName] = (record.copy() as? CKRecord) ?? record
        serverRecordVersions[recordName, default: 0] += 1
        existingRecordNames.insert(recordName)
    }

    /// Hands the caller its own copy, tagged with the version it was read at.
    private func checkedOutCopy(of record: CKRecord, named recordName: String) -> CKRecord {
        guard let copy = record.copy() as? CKRecord else { return record }
        fetchedRecordVersions[ObjectIdentifier(copy)] = serverRecordVersions[recordName, default: 0]
        return copy
    }

    var settingsFetchCount: Int {
        fetchedRecordNameBatches.filter {
            $0 == [SyncedSettingsCloudMapping.recordName]
        }.count
    }
}

/// In-memory `SyncedSettingsStore` recording every value the service adopts. `updatedAt: nil`
/// models a device where the user has never chosen a limit.
@MainActor
private final class FakeSyncedSettingsStore: SyncedSettingsStore {
    var syncedSettings: SyncedSettings?
    private(set) var applied: [SyncedSettings] = []

    init(historyLimit: HistoryLimit, updatedAt: TimeInterval?) {
        self.syncedSettings = SyncedSettings(
            historyLimit: historyLimit,
            updatedAt: updatedAt.map { Date(timeIntervalSinceReferenceDate: $0) } ?? .distantPast
        )
    }

    func applySyncedSettings(_ settings: SyncedSettings) {
        applied.append(settings)
        syncedSettings = settings
    }
}

/// In-memory `SyncableStore` capturing the reconciled snapshot the service applies.
@MainActor
private final class FakeSyncableStore: SyncableStore {
    var items: [ClipboardItem] = []
    var blobURLs: [SyncBlobReference: URL] = [:]
    var onApplyReconciledDurably: (() -> Void)?
    var onWriteBlob: ((SyncBlobReference) async -> Void)?
    private(set) var appliedReconciled: [ClipboardItem]?
    private(set) var writtenBlobs: [SyncBlobReference] = []
    private(set) var deletedBlobs: [SyncBlobReference] = []
    private(set) var syncStatus: SyncStatus = .localOnly(reason: .notProvisioned)
    var writeBlobError: (any Error)?
    var durableApplyError: (any Error)?
    private let blobDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("YankCloudKitSyncTests-\(UUID().uuidString)", isDirectory: true)

    isolated deinit {
        try? FileManager.default.removeItem(at: blobDirectory)
    }

    func itemsForSync() -> [ClipboardItem] { items }

    func applyReconciled(_ canonical: [ClipboardItem]) {
        appliedReconciled = canonical
        items = canonical
    }

    func applyReconciledDurably(_ canonical: [ClipboardItem]) throws {
        if let durableApplyError { throw durableApplyError }
        applyReconciled(canonical)
        onApplyReconciledDurably?()
    }

    func blobURL(for reference: SyncBlobReference) -> URL? {
        blobURLs[reference] ?? reference.containedURL(in: blobDirectory)
    }

    func writeBlob(_ data: Data, reference: SyncBlobReference) async throws {
        if let writeBlobError { throw writeBlobError }
        guard let url = reference.containedURL(in: blobDirectory) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        blobURLs[reference] = url
        writtenBlobs.append(reference)
        await onWriteBlob?(reference)
    }

    func deleteBlob(_ reference: SyncBlobReference) {
        deletedBlobs.append(reference)
        if let url = blobURL(for: reference) {
            try? FileManager.default.removeItem(at: url)
        }
        blobURLs[reference] = nil
    }

    func markSyncStarted() { syncStatus = .syncing }
    func markSyncSucceeded(at date: Date) { syncStatus = .healthy(lastSynced: date) }
    func markSyncFailed(_ message: String) { syncStatus = .failed(message: message) }
    func markSyncUnavailable(reason: SyncStatus.Reason) { syncStatus = .localOnly(reason: reason) }
}
