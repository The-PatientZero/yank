import Foundation
import Testing
@testable import YankiOS

@Suite struct SpotlightIndexerTests {
    @Test func updatesAnExistingIdentifierWhenIndexedContentChanges() async throws {
        let client = RecordingSpotlightClient()
        let storage = SpotlightIndexStorage(client: client)
        let id = UUID()

        try await storage.index([item(id: id, text: "old")])
        try await storage.index([item(id: id, text: "new")])
        try await storage.index([item(id: id, text: "new")])

        let batches = await client.indexBatches
        #expect(batches.count == 2)
        #expect(batches[0].first?.identifier == id.uuidString)
        #expect(batches[1].first?.title == "new")
    }

    @Test func coldStartClearsYankDomainBeforeRebuildingCurrentItems() async throws {
        let client = RecordingSpotlightClient()
        let storage = SpotlightIndexStorage(client: client)

        try await storage.index([item(id: UUID(), text: "current")])

        #expect(await client.deletedDomains == [[SpotlightIndexStorage.domainIdentifier]])
        #expect(await client.indexAttemptCount == 1)
    }

    @Test func failedColdStartClearRemainsEligibleForRetry() async throws {
        let client = RecordingSpotlightClient()
        let storage = SpotlightIndexStorage(client: client)
        await client.failNextDomainDelete()

        do {
            try await storage.index([item(id: UUID(), text: "current")])
            Issue.record("Expected the first domain clear to fail")
        } catch {}
        try await storage.index([item(id: UUID(), text: "current")])

        #expect(await client.domainDeleteAttemptCount == 2)
        #expect(await client.indexAttemptCount == 1)
    }

    @Test func failedIndexRemainsEligibleForRetry() async throws {
        let client = RecordingSpotlightClient()
        let storage = SpotlightIndexStorage(client: client)
        let id = UUID()
        await client.failNextIndex()

        do {
            try await storage.index([item(id: id, text: "retry")])
            Issue.record("Expected the first indexing attempt to fail")
        } catch {}
        try await storage.index([item(id: id, text: "retry")])

        #expect(await client.indexAttemptCount == 2)
    }

    @Test func failedDeletionRemainsEligibleForRetry() async throws {
        let client = RecordingSpotlightClient()
        let storage = SpotlightIndexStorage(client: client)
        let clip = item(id: UUID(), text: "remove")
        try await storage.index([clip])
        await client.failNextDelete()

        do {
            try await storage.index([])
            Issue.record("Expected the first deletion attempt to fail")
        } catch {}
        try await storage.index([])

        #expect(await client.deleteAttemptCount == 2)
    }

    @Test func clearDeletesOnlyYanksDomain() async throws {
        let client = RecordingSpotlightClient()
        let storage = SpotlightIndexStorage(client: client)

        try await storage.clear()

        #expect(await client.deletedDomains == [[SpotlightIndexStorage.domainIdentifier]])
    }

    private func item(id: UUID, text: String) -> ClipboardItem {
        ClipboardItem(id: id, type: .text, textContent: text)
    }
}

private actor RecordingSpotlightClient: SpotlightIndexClient {
    enum TestError: Error { case requestedFailure }

    private(set) var indexBatches: [[SpotlightDocument]] = []
    private(set) var deletedIdentifiers: [[String]] = []
    private(set) var deletedDomains: [[String]] = []
    private var shouldFailIndex = false
    private var shouldFailDelete = false
    private var shouldFailDomainDelete = false

    var indexAttemptCount: Int { indexBatches.count }
    var deleteAttemptCount: Int { deletedIdentifiers.count }
    var domainDeleteAttemptCount: Int { deletedDomains.count }

    func failNextIndex() { shouldFailIndex = true }
    func failNextDelete() { shouldFailDelete = true }
    func failNextDomainDelete() { shouldFailDomainDelete = true }

    func index(_ documents: [SpotlightDocument]) async throws {
        indexBatches.append(documents)
        if shouldFailIndex {
            shouldFailIndex = false
            throw TestError.requestedFailure
        }
    }

    func delete(identifiers: [String]) async throws {
        deletedIdentifiers.append(identifiers)
        if shouldFailDelete {
            shouldFailDelete = false
            throw TestError.requestedFailure
        }
    }

    func delete(domainIdentifiers: [String]) async throws {
        deletedDomains.append(domainIdentifiers)
        if shouldFailDomainDelete {
            shouldFailDomainDelete = false
            throw TestError.requestedFailure
        }
    }
}
