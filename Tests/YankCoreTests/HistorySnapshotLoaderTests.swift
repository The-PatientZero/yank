import Foundation
import Testing
@testable import YankCore

@Suite struct HistorySnapshotLoaderTests {
    @Test func missingFilesLoadAsEmptySnapshot() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }

        let result = HistorySnapshotLoader.load(historyURL: urls.history, tombstonesURL: urls.tombstones)

        let snapshot = try result.get()
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.tombstones.isEmpty)
    }

    @Test func corruptHistoryFileFailsInsteadOfLoadingEmptyHistory() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        try Data("not history json".utf8).write(to: urls.history)

        let result = HistorySnapshotLoader.load(historyURL: urls.history, tombstonesURL: urls.tombstones)

        #expect(result == .failure(.corruptHistory))
    }

    @Test func corruptTombstonesFileFailsInsteadOfDroppingDeletes() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let item = ClipboardItem(id: clipID(1), type: .text, textContent: "kept")
        try JSONEncoder().encode([item]).write(to: urls.history)
        try Data("not tombstone json".utf8).write(to: urls.tombstones)

        let result = HistorySnapshotLoader.load(historyURL: urls.history, tombstonesURL: urls.tombstones)

        #expect(result == .failure(.corruptTombstones))
    }

    private func makeURLs() throws -> (directory: URL, history: URL, tombstones: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankHistorySnapshotLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory: directory,
            history: directory.appendingPathComponent("history.json"),
            tombstones: directory.appendingPathComponent("tombstones.json")
        )
    }
}
