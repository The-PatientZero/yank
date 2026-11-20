import Foundation
import Testing
@testable import Yank

@Suite("Clip Enrichment Service", .serialized)
@MainActor
struct ClipEnrichmentServiceTests {
    @Test("Capture during enrichment schedules one trailing rerun")
    func captureDuringEnrichmentSchedulesTrailingRerun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.service.start()

        fixture.store.add(.text("first captured text"))
        #expect(try await fixture.enricher.waitForRequestCount(1) == ["first captured text"])

        fixture.store.add(.text("second captured text"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.enricher.requestCount == 1)

        await fixture.enricher.completeNext(tags: ["First"])
        #expect(try await fixture.enricher.waitForRequestCount(2) == [
            "first captured text",
            "second captured text"
        ])

        await fixture.enricher.completeNext(tags: ["Second"])
        try await Self.waitUntil {
            fixture.store.items.count == 2
                && fixture.store.items.allSatisfy { $0.aiEnrichedAt != nil }
        }

        #expect(fixture.store.items.first(where: { $0.textContent == "first captured text" })?.aiTags == ["first"])
        #expect(fixture.store.items.first(where: { $0.textContent == "second captured text" })?.aiTags == ["second"])
    }

    @Test("Opting out while enrichment is running discards the result")
    func optingOutWhileEnrichmentIsRunningDiscardsResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.service.start()

        fixture.store.add(.text("captured while enabled"))
        _ = try await fixture.enricher.waitForRequestCount(1)

        fixture.settings.aiTaggingEnabled = false
        await fixture.enricher.completeNext(tags: ["Private"])
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.store.items.first?.aiEnrichedAt == nil)
        #expect(fixture.store.items.first?.aiTags.isEmpty == true)
    }

    @Test("Stopping while enrichment is running discards the result")
    func stoppingWhileEnrichmentIsRunningDiscardsResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.service.start()

        fixture.store.add(.text("captured before stop"))
        _ = try await fixture.enricher.waitForRequestCount(1)

        fixture.service.stop()
        await fixture.enricher.completeNext(tags: ["Stopped"])
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.store.items.first?.aiEnrichedAt == nil)
        #expect(fixture.store.items.first?.aiTags.isEmpty == true)
    }

    @Test("Changed content is not stamped with an obsolete result")
    func changedContentIsNotStampedWithObsoleteResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.service.start()

        fixture.store.add(.text("original captured text"))
        _ = try await fixture.enricher.waitForRequestCount(1)
        let original = try #require(fixture.store.items.first)
        fixture.store.items[0] = ClipboardItem(
            id: original.id,
            type: .text,
            timestamp: original.timestamp,
            sourceApp: original.sourceApp,
            textContent: "replacement captured text",
            tags: original.tags,
            modifiedAt: original.modifiedAt,
            deviceOrigin: original.deviceOrigin
        )

        await fixture.enricher.completeNext(tags: ["Obsolete"])
        try await Task.sleep(for: .milliseconds(30))

        #expect(fixture.store.items.first?.textContent == "replacement captured text")
        #expect(fixture.store.items.first?.aiEnrichedAt == nil)
        #expect(fixture.store.items.first?.aiTags.isEmpty == true)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EnrichmentTestWaitError.timedOut
    }
}

@MainActor
private final class Fixture {
    let store: ClipboardStore
    let enricher = ControlledEnricher()
    let settings = SettingsManager.shared
    let service: ClipEnrichmentService

    private let directory: URL
    private let originalAISetting: Bool

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankClipEnrichmentServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        originalAISetting = settings.aiTaggingEnabled
        settings.aiTaggingEnabled = true
        store = ClipboardStore(settings: .unbounded, storageDirectory: directory)
        service = ClipEnrichmentService(
            store: store,
            enricher: enricher,
            settings: settings,
            debounceDelay: 0.01
        )
    }

    func cleanUp() {
        service.stop()
        store.flushPendingWrites()
        settings.aiTaggingEnabled = originalAISetting
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove enrichment test directory: \(error)")
        }
    }
}

private actor ControlledEnricher: ClipEnricher {
    private var requests: [String] = []
    private var continuations: [CheckedContinuation<ClipEnrichment, Never>] = []

    var requestCount: Int { requests.count }

    func enrich(_ text: String) async -> ClipEnrichment {
        requests.append(text)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ expectedCount: Int) async throws -> [String] {
        for _ in 0 ..< 100 {
            if requests.count >= expectedCount { return requests }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EnrichmentTestWaitError.timedOut
    }

    func completeNext(tags: [String]) {
        guard !continuations.isEmpty else {
            Issue.record("No pending enrichment request to complete")
            return
        }
        continuations.removeFirst().resume(returning: ClipEnrichment(tags: tags))
    }
}

private enum EnrichmentTestWaitError: Error {
    case timedOut
}
