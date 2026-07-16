import Foundation
import Testing
@testable import YankCore

@Suite
@MainActor
struct HistorySnapshotWriterTests {
    private struct WriterURLs {
        let directory: URL
        let history: URL
        let tombstones: URL
    }

    @Test func immediateSaveWritesHistoryAndTombstones() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.immediate"
        )
        let item = makeItem(1, text: "first")
        let tombstoneDate = Date(timeIntervalSinceReferenceDate: 1_234)

        writer.scheduleSave(items: [item], tombstones: [clipID(2): tombstoneDate])
        writer.flush()

        let savedItems = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: urls.history))
        let savedTombstones = TombstoneCodec.decode(try Data(contentsOf: urls.tombstones))

        #expect(savedItems.map(\.id) == [item.id])
        #expect(savedItems.first?.textContent == "first")
        #expect(savedTombstones[clipID(2)] == tombstoneDate)
    }

    @Test func flushPersistsLatestDebouncedSnapshot() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            debounce: .seconds(60),
            queueLabel: "com.yank.tests.history-writer.debounced"
        )
        let stale = makeItem(3, text: "stale")
        let latest = makeItem(4, text: "latest")

        writer.scheduleSave(items: [stale], tombstones: [:])
        writer.scheduleSave(items: [latest], tombstones: [clipID(5): Date(timeIntervalSinceReferenceDate: 5_678)])
        writer.flush()

        let savedItems = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: urls.history))
        let savedTombstones = TombstoneCodec.decode(try Data(contentsOf: urls.tombstones))

        #expect(savedItems.map(\.id) == [latest.id])
        #expect(savedItems.first?.textContent == "latest")
        #expect(Set(savedTombstones.keys) == Set([clipID(5)]))
    }

    @Test func saveAppliesRequestedPrivateFileAttributes() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            writeOptions: .atomic,
            filePermissions: 0o600,
            fileProtection: .complete,
            queueLabel: "com.yank.tests.history-writer.attributes"
        )

        writer.scheduleSave(items: [makeItem(6, text: "private")], tombstones: [clipID(7): Date()])
        writer.flush()

        let historyAttributes = try FileManager.default.attributesOfItem(atPath: urls.history.path)
        let tombstoneAttributes = try FileManager.default.attributesOfItem(atPath: urls.tombstones.path)
        #expect(historyAttributes[.posixPermissions] as? Int == 0o600)
        #expect(tombstoneAttributes[.posixPermissions] as? Int == 0o600)
        expectProtection(historyAttributes[.protectionKey] as? FileProtectionType, matches: .complete)
        expectProtection(tombstoneAttributes[.protectionKey] as? FileProtectionType, matches: .complete)
    }

    @Test func flushReportsLatestSnapshotWriteFailure() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        try FileManager.default.createDirectory(at: urls.history, withIntermediateDirectories: false)
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.failure"
        )

        writer.scheduleSave(items: [makeItem(8, text: "cannot persist")], tombstones: [:])

        switch writer.flush() {
        case .success:
            Issue.record("Expected the history write failure to reach flush")
        case .failure:
            break
        }
    }

    @Test func postWriteWorkRunsOnlyAfterSuccessfulSnapshot() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let marker = urls.directory.appendingPathComponent("projection-ready")
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.post-write"
        )

        writer.scheduleSave(items: [makeItem(9, text: "ready")], tombstones: [:]) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }

        try writer.flush().get()
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeURLs() throws -> WriterURLs {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankHistorySnapshotWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return WriterURLs(
            directory: directory,
            history: directory.appendingPathComponent("history.json"),
            tombstones: directory.appendingPathComponent("tombstones.json")
        )
    }

    private func makeItem(_ id: Int, text: String) -> ClipboardItem {
        ClipboardItem(
            id: clipID(id),
            type: .text,
            timestamp: Date(timeIntervalSinceReferenceDate: Double(id)),
            textContent: text
        )
    }

    private func expectProtection(_ actual: FileProtectionType?, matches requested: FileProtectionType) {
        if actual == requested { return }
        #if os(macOS)
        if actual == nil { return }
        if requested == .complete, actual == .completeUntilFirstUserAuthentication { return }
        #endif
        #expect(actual == requested)
    }
}
