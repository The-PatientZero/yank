import Foundation
import Testing
@testable import YankCore

@Suite struct ShareCaptureInboxTests {
    @Test func enqueuesTextAndRemovesItIdempotently() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareCaptureInbox(rootURL: root, writeOptions: .atomic)

        let entry = try inbox.enqueue(text: "shared text", sourceApp: "Share")

        #expect(try inbox.pendingEntries() == [entry])
        try inbox.remove(entry)
        try inbox.remove(entry)
        #expect(try inbox.pendingEntries().isEmpty)
    }

    @Test func imagePayloadSurvivesUntilEntryIsRemoved() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareCaptureInbox(rootURL: root, writeOptions: .atomic)
        let payload = Data([1, 2, 3])

        let entry = try inbox.enqueue(imagePNG: payload, sourceApp: "Share")

        #expect(try inbox.imagePayload(for: entry) == payload)
        try inbox.remove(entry)
        #expect(throws: ShareCaptureInbox.Error.missingPayload) {
            try inbox.imagePayload(for: entry)
        }
    }

    @Test func rejectsWorkBeyondConfiguredQuotaBeforeWriting() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareCaptureInbox(
            rootURL: root,
            maxPendingCaptures: 1,
            maxPendingBytes: 1_024,
            writeOptions: .atomic
        )
        _ = try inbox.enqueue(text: "first")

        #expect(throws: ShareCaptureInbox.Error.quotaExceeded) {
            try inbox.enqueue(text: "second")
        }
        #expect(try inbox.pendingEntries().count == 1)
    }

    @Test func corruptedEntryFailsClosedWithoutDeletingIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareCaptureInbox(rootURL: root, writeOptions: .atomic)
        try FileManager.default.createDirectory(
            at: inbox.entriesURL,
            withIntermediateDirectories: true
        )
        let corruptedURL = inbox.entriesURL.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: corruptedURL)

        #expect(throws: ShareCaptureInbox.Error.invalidEntry) {
            try inbox.pendingEntries()
        }
        #expect(FileManager.default.fileExists(atPath: corruptedURL.path))
    }

    @Test func recoveryDiscardsCorruptionAndReturnsValidEntries() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareCaptureInbox(rootURL: root, writeOptions: .atomic)
        let valid = try inbox.enqueue(text: "keep me")
        let corruptedURL = inbox.entriesURL.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: corruptedURL)

        #expect(try inbox.recoverablePendingEntries() == [valid])
        #expect(!FileManager.default.fileExists(atPath: corruptedURL.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareCaptureInboxTests-\(UUID().uuidString)", isDirectory: true)
    }
}
