import Foundation

enum TextChunker {
    struct Page: Equatable {
        let text: String
        let reachedEOF: Bool
    }

    static func bytesToRead(charCount: Int, totalBytes: Int) -> Int {
        min(charCount * 4, totalBytes)
    }

    static func page(from data: Data, charCount: Int) -> Page {
        let fullChunk = String(decoding: data, as: UTF8.self)
        let exact = String(fullChunk.prefix(charCount))
        return Page(text: exact, reachedEOF: fullChunk.count < charCount)
    }

    static func page(from content: String, charCount: Int) -> Page {
        Page(text: String(content.prefix(charCount)), reachedEOF: content.count <= charCount)
    }
}
