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

    @Test func skipsIndividuallyMalformedItemsKeepingTheRest() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        // A valid JSON array whose middle element is missing the required id/type/timestamp.
        let good = ClipboardItem(id: clipID(1), type: .text, textContent: "keep")
        let goodObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let array: [Any] = [goodObject, ["nonsense": true], goodObject]
        try JSONSerialization.data(withJSONObject: array).write(to: urls.history)

        let snapshot = try HistorySnapshotLoader
            .load(historyURL: urls.history, tombstonesURL: urls.tombstones).get()
        #expect(snapshot.items.count == 2)
        #expect(snapshot.skippedItemCount == 1)
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
