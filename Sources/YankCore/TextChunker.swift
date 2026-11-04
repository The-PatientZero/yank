import Foundation

enum TextChunker {
    struct Page: Equatable {
        let text: String
        let reachedEOF: Bool
    }

    /// Characters taken from the front of a byte window, and the bytes they occupy in the file.
    struct DataPage: Equatable {
        let text: String
        let consumedBytes: Int
    }

    private static let maxBytesPerCharacterGuess = 4

    static func bytesToRead(charCount: Int, totalBytes: Int) -> Int {
        min(charCount * maxBytesPerCharacterGuess, totalBytes)
    }

    /// Takes the first `charCount` characters (grapheme clusters) of a window that starts on a
    /// character boundary. Returns nil when the window is too short to be sure of them: a
    /// multi-scalar character needs far more than four bytes, and a window that stops inside a
    /// character, or exactly at the end of the last one wanted, may be cutting a cluster in two.
    /// A window that reaches the end of the file is always enough. The byte count comes from
    /// the characters kept, never from the window, so the next page starts exactly where this
    /// one ended.
    static func page(from data: Data, charCount: Int, windowReachesEOF: Bool) -> DataPage? {
        let usable = windowReachesEOF ? data : data.prefix(completeUTF8Length(of: data))
        let decoded = String(decoding: usable, as: UTF8.self)
        guard let end = decoded.index(decoded.startIndex, offsetBy: charCount, limitedBy: decoded.endIndex) else {
            return windowReachesEOF ? DataPage(text: decoded, consumedBytes: decoded.utf8.count) : nil
        }
        if end == decoded.endIndex, !windowReachesEOF { return nil }
        let text = String(decoded[..<end])
        return DataPage(text: text, consumedBytes: text.utf8.count)
    }

    static func page(from content: String, charCount: Int) -> Page {
        Page(text: String(content.prefix(charCount)), reachedEOF: content.count <= charCount)
    }

    /// Length of the longest prefix that does not end in the middle of a UTF-8 sequence, so a
    /// window cut at an arbitrary byte never decodes to a replacement character.
    private static func completeUTF8Length(of data: Data) -> Int {
        let bytes = Array(data.suffix(maxBytesPerCharacterGuess - 1))
        for back in stride(from: 1, through: bytes.count, by: 1) {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }   // continuation byte, keep looking
            let sequenceLength = byte >= 0b1111_0000 ? 4 : byte >= 0b1110_0000 ? 3 : byte >= 0b1100_0000 ? 2 : 1
            return sequenceLength > back ? data.count - back : data.count
        }
        return data.count
    }
}
