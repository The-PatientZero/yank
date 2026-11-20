import Foundation
import Testing
@testable import YankCore

@Suite struct PasteboardArchiveTests {
    @Test func isRichDetectsFidelityTypes() {
        #expect(PasteboardArchive.isRich(utis: ["public.utf8-plain-text", "public.rtf"]))
        #expect(PasteboardArchive.isRich(utis: ["public.html"]))
        #expect(PasteboardArchive.isRich(utis: ["public.png", "com.adobe.pdf"]))
        #expect(PasteboardArchive.isRich(utis: ["com.apple.flat-rtfd"]))
    }

    @Test func isRichIgnoresPlainContent() {
        #expect(!(PasteboardArchive.isRich(utis: ["public.utf8-plain-text"])))
        #expect(!(PasteboardArchive.isRich(utis: ["public.png", "public.tiff"])))
        #expect(!(PasteboardArchive.isRich(utis: [])))
    }

    @Test func binaryPlistRoundTripPreservesRepresentations() throws {
        let archive = PasteboardArchive(representations: [
            .init(uti: "public.rtf", data: Data([0x7B, 0x5C, 0x72, 0x74, 0x66])),  // "{\rtf"
            .init(uti: "public.utf8-plain-text", data: Data("hello".utf8))
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(archive)
        let decoded = try PropertyListDecoder().decode(PasteboardArchive.self, from: data)

        #expect(decoded == archive)
        #expect(decoded.representations.count == 2)
        #expect(decoded.totalBytes == 10)
        #expect(!(decoded.isEmpty))
    }
}
