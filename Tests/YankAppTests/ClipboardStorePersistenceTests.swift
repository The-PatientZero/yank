import Foundation
import Testing
@testable import Yank

@Suite("Clipboard Store Persistence")
@MainActor
struct ClipboardStorePersistenceTests {
    @Test("Corrupt existing history disables saves instead of overwriting")
    func corruptExistingHistoryDisablesSavesInsteadOfOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankClipboardStorePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyURL = directory.appendingPathComponent("history.json")
        let corruptData = Data("not history json".utf8)
        try corruptData.write(to: historyURL)

        let store = ClipboardStore(settings: .unbounded, storageDirectory: directory)

        #expect(store.storageUnavailable)
        store.add(.text("new clip", sourceApp: "Test"))
        store.flushPendingWrites()

        #expect(try Data(contentsOf: historyURL) == corruptData)
    }
}
