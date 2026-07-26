import Foundation
import Testing
@testable import YankCore

@Suite struct HistorySnapshotLoaderTests {
    private struct TestEnvelope: Codable {
        let version: Int
        let transactionID: UUID
        let historyData: Data
        let tombstonesData: Data
        let writeOptionsRawValue: UInt
        let filePermissions: Int?
        let fileProtectionRawValue: String?
    }

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

    @Test func invalidEnvelopeLeavesCanonicalFilesByteIdentical() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let canonicalHistory = try JSONEncoder().encode([
            ClipboardItem(id: clipID(20), type: .text, textContent: "canonical")
        ])
        let canonicalTombstones = try #require(TombstoneCodec.encode([
            clipID(21): Date(timeIntervalSinceReferenceDate: 2_100)
        ]))
        try canonicalHistory.write(to: urls.history)
        try canonicalTombstones.write(to: urls.tombstones)
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        try Data("not a transaction".utf8).write(to: transactionURL)

        let result = HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        )

        #expect(result == .failure(.corruptTransaction))
        #expect(try Data(contentsOf: urls.history) == canonicalHistory)
        #expect(try Data(contentsOf: urls.tombstones) == canonicalTombstones)
        #expect(FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func envelopeWithMalformedHistoryItemFailsClosedBeforeReplay() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let canonicalHistory = try JSONEncoder().encode([
            ClipboardItem(id: clipID(22), type: .text, textContent: "keep canonical")
        ])
        let canonicalTombstones = try #require(TombstoneCodec.encode([:]))
        try canonicalHistory.write(to: urls.history)
        try canonicalTombstones.write(to: urls.tombstones)

        let malformedHistory = try JSONSerialization.data(withJSONObject: [
            ["nonsense": true]
        ])
        let envelope = TestEnvelope(
            version: HistorySnapshotTransaction.currentVersion,
            transactionID: UUID(),
            historyData: malformedHistory,
            tombstonesData: canonicalTombstones,
            writeOptionsRawValue: Data.WritingOptions.atomic.rawValue,
            filePermissions: nil,
            fileProtectionRawValue: nil
        )
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        try JSONEncoder().encode(envelope).write(to: transactionURL)

        let result = HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        )

        #expect(result == .failure(.corruptTransaction))
        #expect(try Data(contentsOf: urls.history) == canonicalHistory)
        #expect(try Data(contentsOf: urls.tombstones) == canonicalTombstones)
        #expect(FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func envelopeWithInvalidTombstoneUUIDLeavesCanonicalFilesByteIdentical() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let canonicalHistory = try JSONEncoder().encode([
            ClipboardItem(id: clipID(23), type: .text, textContent: "keep live item")
        ])
        let canonicalTombstones = try #require(TombstoneCodec.encode([
            clipID(24): Date(timeIntervalSinceReferenceDate: 2_400)
        ]))
        try canonicalHistory.write(to: urls.history)
        try canonicalTombstones.write(to: urls.tombstones)
        let invalidTombstones = try JSONEncoder().encode([
            "not-a-uuid": Date(timeIntervalSinceReferenceDate: 2_500)
        ])
        let envelope = TestEnvelope(
            version: HistorySnapshotTransaction.currentVersion,
            transactionID: UUID(),
            historyData: canonicalHistory,
            tombstonesData: invalidTombstones,
            writeOptionsRawValue: Data.WritingOptions.atomic.rawValue,
            filePermissions: nil,
            fileProtectionRawValue: nil
        )
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        try JSONEncoder().encode(envelope).write(to: transactionURL)

        let result = HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        )

        #expect(result == .failure(.corruptTransaction))
        #expect(try Data(contentsOf: urls.history) == canonicalHistory)
        #expect(try Data(contentsOf: urls.tombstones) == canonicalTombstones)
        #expect(FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func unsupportedEnvelopeVersionLeavesCanonicalFilesByteIdentical() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let canonicalHistory = try JSONEncoder().encode([
            ClipboardItem(id: clipID(25), type: .text, textContent: "known version")
        ])
        let canonicalTombstones = try #require(TombstoneCodec.encode([
            clipID(26): Date(timeIntervalSinceReferenceDate: 2_600)
        ]))
        try canonicalHistory.write(to: urls.history)
        try canonicalTombstones.write(to: urls.tombstones)
        let envelope = TestEnvelope(
            version: HistorySnapshotTransaction.currentVersion + 1,
            transactionID: UUID(),
            historyData: canonicalHistory,
            tombstonesData: canonicalTombstones,
            writeOptionsRawValue: Data.WritingOptions.atomic.rawValue,
            filePermissions: nil,
            fileProtectionRawValue: nil
        )
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        try JSONEncoder().encode(envelope).write(to: transactionURL)

        let result = HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        )

        #expect(result == .failure(.corruptTransaction))
        #expect(try Data(contentsOf: urls.history) == canonicalHistory)
        #expect(try Data(contentsOf: urls.tombstones) == canonicalTombstones)
        #expect(FileManager.default.fileExists(atPath: transactionURL.path))
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
