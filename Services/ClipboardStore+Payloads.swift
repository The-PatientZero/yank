import Foundation
import AppKit
import Observation

@MainActor
extension ClipboardStore {
    func image(for item: ClipboardItem) -> NSImage? {
        guard item.type == .image else { return nil }
        return Self.image(at: blobURL(for: item))
    }

    static func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Copies each image clip's blob into `folder` as `image-NNNN.png`, skipping non-image
    /// items. Throws `.missingBlob` for a missing blob; returns the count written.
    @discardableResult
    func exportImages(_ items: [ClipboardItem], to folder: URL) throws(ImageExportError) -> Int {
        var written = 0
        for item in items where item.type == .image {
            guard let source = blobURL(for: item) else {
                throw .missingBlob(itemID: item.id)
            }
            written += 1
            let fileName = "image-\(String(format: "%04d", written)).png"
            let destination = folder.appendingPathComponent(fileName)
            do {
                try blobStore.copyImageBlob(from: source, to: destination)
            } catch {
                throw .copyFailed(itemID: item.id, underlying: error)
            }
        }
        return written
    }

    func richArchiveAsync(for item: ClipboardItem) async -> PasteboardArchive? {
        guard let url = blobStore.richArchiveURL(for: item) else { return nil }
        do {
            return try await ClipboardPayloadLoader.richArchive(for: item, blobURL: url)
        } catch {
            Log.store.error("Failed to load rich archive: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load full text content from file (lazy loading for large text)
    func fullText(for item: ClipboardItem) -> String? {
        guard let filename = item.textFilename else { return item.textContent }
        guard let url = blobStore.textURL(filename: filename) else {
            return item.textContent
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Log.store.error("Failed to load text file: \(error.localizedDescription)")
            return item.textContent
        }
    }

    func fullTextAsync(for item: ClipboardItem) async -> String? {
        let url = blobURL(for: item)
        do {
            return try await ClipboardPayloadLoader.fullText(for: item, blobURL: url)
        } catch {
            Log.store.error("Failed to load text file: \(error.localizedDescription)")
            return item.textContent
        }
    }

    /// The text "Paste as Text" inserts: an image's recognized text, or a text clip's full text.
    /// Returns nil when there is nothing to paste, including when a file-backed clip's blob cannot
    /// be loaded; the stored preview is never used as a stand-in for the full text.
    func pasteAsTextContent(for item: ClipboardItem) async -> String? {
        switch item.type {
        case .image:
            return item.recognizedText
        case .text:
            do {
                let text = try await ClipboardPayloadLoader.fullText(for: item, blobURL: blobURL(for: item))
                return text.isEmpty ? nil : text
            } catch {
                Log.store.error("Failed to load text for Paste as Text: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func imagePNGDataAsync(for item: ClipboardItem) async -> Data? {
        do {
            return try await ClipboardPayloadLoader.imagePNGData(for: item, blobURL: blobURL(for: item))
        } catch {
            Log.store.error("Failed to load image blob: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load a chunk of text content, reading only what's necessary
    nonisolated static func textChunk(
        for item: ClipboardItem,
        textURL: URL?,
        charCount: Int,
        byteOffset: Int = 0
    ) -> TextChunkPage? {
        TextChunkReader.page(
            for: item, textURL: textURL, charCount: charCount, byteOffset: byteOffset
        ) { error in
            Log.store.error("Failed to read text chunk: \(error.localizedDescription)")
        }
    }

    /// Total size of an item, in bytes.
    func itemSize(for item: ClipboardItem) -> Int? {
        if let inline = item.inlineSizeBytes { return inline }

        switch item.type {
        case .text:
            guard let filename = item.textFilename,
                  let url = blobStore.textURL(filename: filename) else {
                return nil
            }
            return cachedFileSize(id: item.id, url: url)
        case .image:
            guard let filename = item.imageFilename else { return nil }
            guard let url = blobStore.imageURL(filename: filename) else {
                return nil
            }
            return cachedFileSize(id: item.id, url: url)
        }
    }

    private func cachedFileSize(id: UUID, url: URL) -> Int? {
        if let cached = sizeCache[id] { return cached }
        guard let size = blobStore.fileSize(at: url) else { return nil }
        sizeCache[id] = size
        return size
    }
}

/// Failure modes for `ClipboardStore.exportImages(_:to:)`.
enum ImageExportError: Error, LocalizedError {
    case missingBlob(itemID: UUID)
    case copyFailed(itemID: UUID, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingBlob:
            "An image could not be found in the clipboard store."
        case .copyFailed(_, let underlying):
            "Failed to save an image: \(underlying.localizedDescription)"
        }
    }
}

extension ClipboardItem {
    /// Whether Paste as Text is expected to have something to insert, mirroring
    /// `ClipboardStore.pasteAsTextContent(for:)`. Advisory for text clips: an empty or unreadable
    /// file passes here and is reported when the paste is tried.
    var canPasteAsText: Bool {
        switch type {
        case .text: true
        case .image: recognizedText != nil
        }
    }
}
