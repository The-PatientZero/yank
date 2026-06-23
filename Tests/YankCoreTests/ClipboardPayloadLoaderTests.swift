import Foundation
import Testing
@testable import YankCore

@Suite struct ClipboardPayloadLoaderTests {
    @Test func inlineTextReturnsTextContent() async throws {
        let item = ClipboardItem(id: clipID(200), type: .text, textContent: "hello")

        let text = try await ClipboardPayloadLoader.fullText(for: item, blobURL: nil)

        #expect(text == "hello")
    }

    @Test func fileBackedTextReturnsFullBlobText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("\(clipID(201).uuidString).txt")
        try "full text beyond preview".write(to: url, atomically: true, encoding: .utf8)
        let item = ClipboardItem(
            id: clipID(201),
            type: .text,
            textContent: "preview",
            textFilename: url.lastPathComponent
        )

        let text = try await ClipboardPayloadLoader.fullText(for: item, blobURL: url)

        #expect(text == "full text beyond preview")
    }

    @Test func imagePayloadReturnsRawPNGData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let url = directory.appendingPathComponent("\(clipID(202).uuidString).png")
        try data.write(to: url)
        let item = ClipboardItem(id: clipID(202), type: .image, imageFilename: url.lastPathComponent)

        let loaded = try await ClipboardPayloadLoader.imagePNGData(for: item, blobURL: url)

        #expect(loaded == data)
    }

    @Test func richArchiveReturnsDecodedPasteboardArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = PasteboardArchive(
            representations: [
                .init(uti: "public.html", data: Data("<b>Hello</b>".utf8))
            ]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let filename = "\(clipID(203).uuidString).plist"
        let url = directory.appendingPathComponent(filename)
        try encoder.encode(archive).write(to: url)
        let item = ClipboardItem(id: clipID(203), type: .text, richFilename: filename)

        let loaded = try await ClipboardPayloadLoader.richArchive(for: item, blobURL: url)

        #expect(loaded == archive)
    }
}
