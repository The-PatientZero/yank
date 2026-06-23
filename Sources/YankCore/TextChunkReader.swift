import Foundation

enum TextChunkReader {
    static func page(
        for item: ClipboardItem,
        textURL: URL?,
        charCount: Int,
        onError: (any Error) -> Void = { _ in }
    ) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        if let url = textURL, item.textFilename != nil {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let totalBytes = attributes[.size] as? Int ?? 0
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                let maximumBytesToRead = TextChunker.bytesToRead(charCount: charCount, totalBytes: totalBytes)
                let data = try handle.read(upToCount: maximumBytesToRead) ?? Data()
                let page = TextChunker.page(from: data, charCount: charCount)
                return (page.text, totalBytes, page.reachedEOF)
            } catch {
                onError(error)
                return nil
            }
        }

        let content = item.textContent ?? ""
        let totalBytes = item.originalSizeBytes ?? content.utf8.count
        let page = TextChunker.page(from: content, charCount: charCount)
        return (page.text, totalBytes, page.reachedEOF)
    }
}
