import Foundation
import Testing
@testable import YankCore

@Suite struct KeyboardHistoryReaderTests {
    @Test func readsTheHostsBoundedProjection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectionURL = root.appendingPathComponent(KeyboardHistoryProjection.filename)
        let existing = ClipboardItem.text("existing")
        try KeyboardHistoryProjection(items: [existing]).write(to: projectionURL, options: .atomic)

        let items = try KeyboardHistoryReader(projectionURL: projectionURL).load()

        #expect(items.map(\.textContent) == ["existing"])
    }

    @Test func missingProjectionIsAnEmptyValidState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let items = try KeyboardHistoryReader(
            projectionURL: root.appendingPathComponent(KeyboardHistoryProjection.filename)
        ).load()

        #expect(items.isEmpty)
    }

    @Test func expiredQueuedSharesAreHiddenWithTheProjectionsWindow() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 100_000)
        let projectionURL = root.appendingPathComponent(KeyboardHistoryProjection.filename)
        try KeyboardHistoryProjection(items: [], retentionMinutes: 60).write(to: projectionURL, options: .atomic)
        let inbox = ShareCaptureInbox(rootURL: root.appendingPathComponent("inbox"), writeOptions: .atomic)
        let stale = try inbox.enqueue(text: "stale share", createdAt: now.addingTimeInterval(-2 * 3_600))
        let fresh = try inbox.enqueue(text: "fresh share", createdAt: now.addingTimeInterval(-10 * 60))
        try inbox.publishKeyboardPreview(for: stale)
        try inbox.publishKeyboardPreview(for: fresh)

        let items = try KeyboardHistoryReader(
            projectionURL: projectionURL,
            previewsURL: inbox.previewsURL,
            inboxEntriesURL: inbox.entriesURL
        ).load(now: now)

        #expect(items.map(\.textContent) == ["fresh share"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardHistoryReaderTests-\(UUID().uuidString)", isDirectory: true)
    }
}
