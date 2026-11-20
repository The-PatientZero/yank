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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardHistoryReaderTests-\(UUID().uuidString)", isDirectory: true)
    }
}
