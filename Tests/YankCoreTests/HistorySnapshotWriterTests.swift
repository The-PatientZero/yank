import Foundation
import Testing
@testable import YankCore

@Suite
@MainActor
struct HistorySnapshotWriterTests {
    private enum InjectedFailure: Error {
        case interruption
    }

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
        let callbackSawEnvelope = urls.directory.appendingPathComponent("callback-saw-envelope")
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.post-write"
        )

        writer.scheduleSave(items: [makeItem(9, text: "ready")], tombstones: [:]) {
            if FileManager.default.fileExists(atPath: transactionURL.path) {
                FileManager.default.createFile(atPath: callbackSawEnvelope.path, contents: Data())
            }
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }

        try writer.flush().get()
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: callbackSawEnvelope.path))
    }

    @Test func keyboardProjectionPublicationPreservesWriterOrder() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let projectionURL = urls.directory.appendingPathComponent(KeyboardHistoryProjection.filename)
        let stale = makeItem(30, text: "stale")
        let latest = makeItem(31, text: "latest")
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.projection-order"
        )

        writer.scheduleKeyboardProjection(items: [stale], to: projectionURL)
        writer.scheduleSave(
            items: [latest],
            tombstones: [:],
            keyboardProjectionURL: projectionURL
        )
        try writer.flush().get()

        let projection = try KeyboardHistoryProjection.load(from: projectionURL)
        #expect(projection.items.map(\.id) == [latest.id])
    }

    @Test func interruptionBetweenCanonicalWritesRecoversTheCompletePair() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let removedID = clipID(10)
        let liveItem = makeItem(11, text: "survives interruption")
        let deletedAt = Date(timeIntervalSinceReferenceDate: 9_876)
        try JSONEncoder().encode([makeItem(10, text: "must stay deleted")]).write(to: urls.history)
        try #require(TombstoneCodec.encode([:])).write(to: urls.tombstones)
        let callbackMarker = urls.directory.appendingPathComponent("callback-ran")
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.interrupted",
            failureInjector: { phase in
                if case .historyReplaced = phase {
                    throw InjectedFailure.interruption
                }
            }
        )

        writer.scheduleSave(items: [liveItem], tombstones: [removedID: deletedAt]) {
            FileManager.default.createFile(atPath: callbackMarker.path, contents: Data())
        }
        #expect(throws: InjectedFailure.interruption) {
            try writer.flush().get()
        }

        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        #expect(FileManager.default.fileExists(atPath: transactionURL.path))
        #expect(!FileManager.default.fileExists(atPath: callbackMarker.path))
        #expect(TombstoneCodec.decode(try Data(contentsOf: urls.tombstones)).isEmpty)

        let recovered = try HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        ).get()
        #expect(recovered.items.map(\.id) == [liveItem.id])
        #expect(recovered.tombstones == [removedID: deletedAt])
        #expect(!FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func existingTransactionIsRecoveredBeforeANewEnvelopeIsStaged() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let first = makeItem(12, text: "first checkpoint")
        let second = makeItem(13, text: "second checkpoint")

        let firstWriter = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.first-checkpoint",
            failureInjector: { phase in
                if case .transactionStaged = phase {
                    throw InjectedFailure.interruption
                }
            }
        )
        firstWriter.scheduleSave(items: [first], tombstones: [:])
        #expect(throws: InjectedFailure.interruption) {
            try firstWriter.flush().get()
        }

        let secondWriter = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.second-checkpoint",
            failureInjector: { phase in
                if case .transactionStaged = phase {
                    throw InjectedFailure.interruption
                }
            }
        )
        secondWriter.scheduleSave(items: [second], tombstones: [:])
        #expect(throws: InjectedFailure.interruption) {
            try secondWriter.flush().get()
        }

        // The first checkpoint had to be replayed before its envelope could be replaced.
        let canonicalItems = try JSONDecoder().decode(
            [ClipboardItem].self,
            from: Data(contentsOf: urls.history)
        )
        #expect(canonicalItems.map(\.id) == [first.id])

        let recovered = try HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        ).get()
        #expect(recovered.items.map(\.id) == [second.id])
    }

    @Test func interruptionAfterBothWritesReplaysIdempotentlyBeforeCleanup() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let item = makeItem(14, text: "already committed")
        let deletedAt = Date(timeIntervalSinceReferenceDate: 14_000)
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            filePermissions: 0o600,
            fileProtection: .complete,
            queueLabel: "com.yank.tests.history-writer.cleanup-interrupted",
            failureInjector: { phase in
                if case .tombstonesReplaced = phase {
                    throw InjectedFailure.interruption
                }
            }
        )

        writer.scheduleSave(items: [item], tombstones: [clipID(15): deletedAt])
        #expect(throws: InjectedFailure.interruption) {
            try writer.flush().get()
        }

        let transactionURL = HistorySnapshotTransaction.transactionURL(for: urls.history)
        #expect(FileManager.default.fileExists(atPath: transactionURL.path))
        let transactionAttributes = try FileManager.default.attributesOfItem(atPath: transactionURL.path)
        #expect(transactionAttributes[.posixPermissions] as? Int == 0o600)
        expectProtection(transactionAttributes[.protectionKey] as? FileProtectionType, matches: .complete)
        let committedHistory = try Data(contentsOf: urls.history)
        let committedTombstones = try Data(contentsOf: urls.tombstones)

        let recovered = try HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        ).get()
        #expect(recovered.items.map(\.id) == [item.id])
        #expect(recovered.tombstones == [clipID(15): deletedAt])
        #expect(try Data(contentsOf: urls.history) == committedHistory)
        #expect(try Data(contentsOf: urls.tombstones) == committedTombstones)
        #expect(!FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func stagedOnlyRecoveryAppliesCanonicalPrivateAttributes() throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let item = makeItem(16, text: "recover with attributes")
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            filePermissions: 0o600,
            fileProtection: .complete,
            queueLabel: "com.yank.tests.history-writer.staged-attributes",
            failureInjector: { phase in
                if case .transactionStaged = phase {
                    throw InjectedFailure.interruption
                }
            }
        )

        writer.scheduleSave(items: [item], tombstones: [clipID(17): Date()])
        #expect(throws: InjectedFailure.interruption) {
            try writer.flush().get()
        }
        #expect(!FileManager.default.fileExists(atPath: urls.history.path))
        #expect(!FileManager.default.fileExists(atPath: urls.tombstones.path))

        _ = try HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        ).get()
        let historyAttributes = try FileManager.default.attributesOfItem(atPath: urls.history.path)
        let tombstoneAttributes = try FileManager.default.attributesOfItem(atPath: urls.tombstones.path)
        #expect(historyAttributes[.posixPermissions] as? Int == 0o600)
        #expect(tombstoneAttributes[.posixPermissions] as? Int == 0o600)
        expectProtection(historyAttributes[.protectionKey] as? FileProtectionType, matches: .complete)
        expectProtection(tombstoneAttributes[.protectionKey] as? FileProtectionType, matches: .complete)
    }

    @Test func asyncReceiptsFollowTheSnapshotThatActuallySubsumesTheirWrite() async throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let first = makeItem(18, text: "coalesced away")
        let latest = makeItem(19, text: "latest snapshot")
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            debounce: .milliseconds(10),
            queueLabel: "com.yank.tests.history-writer.async-coalescing"
        )

        let firstReceipt = writer.scheduleSave(items: [first], tombstones: [:])
        let latestReceipt = writer.scheduleSave(items: [latest], tombstones: [:])

        try await firstReceipt.value().get()
        try await latestReceipt.value().get()
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones
        ).get()
        #expect(snapshot.items.map(\.id) == [latest.id])
    }

    @Test func asyncReceiptKeepsAnAlreadyDispatchedFailureExact() async throws {
        let urls = try makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let writer = HistorySnapshotWriter(
            historyURL: urls.history,
            tombstonesURL: urls.tombstones,
            queueLabel: "com.yank.tests.history-writer.async-exact-failure"
        )
        try FileManager.default.createDirectory(
            at: urls.history,
            withIntermediateDirectories: false
        )

        let failedReceipt = writer.scheduleSave(
            items: [makeItem(20, text: "failed")],
            tombstones: [:]
        )
        await #expect(throws: (any Error).self) {
            try await failedReceipt.value().get()
        }

        try FileManager.default.removeItem(at: urls.history)
        let successfulReceipt = writer.scheduleSave(
            items: [makeItem(21, text: "recovered")],
            tombstones: [:]
        )
        try await successfulReceipt.value().get()
        await #expect(throws: (any Error).self) {
            try await failedReceipt.value().get()
        }
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
