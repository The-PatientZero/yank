import Foundation

struct TextChunkPage: Equatable, Sendable {
    let text: String
    let totalBytes: Int
    let reachedEOF: Bool
    /// Where the page after this one starts in the file: `byteOffset` plus the bytes of the
    /// characters in `text`. Pass it back as `byteOffset` to read the next page.
    let nextByteOffset: Int
}

enum TextChunkReader {
    /// Reads `charCount` characters starting at `byteOffset`, which must be 0 or a
    /// `nextByteOffset` returned earlier. A file-backed page reads only the bytes it needs.
    static func page(
        for item: ClipboardItem,
        textURL: URL?,
        charCount: Int,
        byteOffset: Int = 0,
        onError: (any Error) -> Void = { _ in }
    ) -> TextChunkPage? {
        if let url = textURL, item.textFilename != nil {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let totalBytes = attributes[.size] as? Int ?? 0
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                // At least one byte, so a window that is too small can always grow by doubling.
                var windowBytes = max(
                    TextChunker.bytesToRead(charCount: charCount, totalBytes: max(totalBytes - byteOffset, 0)),
                    1
                )
                while true {
                    try handle.seek(toOffset: UInt64(byteOffset))
                    let data = try handle.read(upToCount: windowBytes) ?? Data()
                    let reachesEOF = byteOffset + data.count >= totalBytes
                    if let page = TextChunker.page(from: data, charCount: charCount, windowReachesEOF: reachesEOF) {
                        let next = byteOffset + page.consumedBytes
                        return TextChunkPage(
                            text: page.text,
                            totalBytes: totalBytes,
                            reachedEOF: next >= totalBytes,
                            nextByteOffset: next
                        )
                    }
                    windowBytes *= 2
                }
            } catch {
                onError(error)
                return nil
            }
        }

        let content = item.textContent ?? ""
        let totalBytes = item.originalSizeBytes ?? content.utf8.count
        let page = TextChunker.page(from: content, charCount: charCount)
        return TextChunkPage(
            text: page.text,
            totalBytes: totalBytes,
            reachedEOF: page.reachedEOF,
            nextByteOffset: page.text.utf8.count
        )
    }
}
