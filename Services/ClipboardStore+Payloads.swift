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

    /// Copy each image clip's blob into `folder` as `image-0001.png`, `image-0002.png`, …
    /// Moves the blob-copy `FileManager` I/O out of the SwiftUI view and into
    /// the store, which owns the blob layout. Non-image items are skipped; an item whose
    /// blob is missing is reported rather than silently dropped. Returns the number of
    /// images written so the caller can report progress.
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

    func saveImage(_ data: Data) -> String? {
        blobStore.saveImage(data)
    }

    /// Persist a full pasteboard archive (binary plist) and return its filename (#11).
    func saveRichArchive(_ archive: PasteboardArchive) -> String? {
        blobStore.saveRichArchive(archive)
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

    /// Save large text off the main actor and return the filename. Used by clipboard
    /// capture, where a multi-MB write should never stall the menu-bar UI.
    func saveTextAsync(_ text: String) async -> String? {
        await blobStore.saveTextAsync(text)
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

    func imagePNGDataAsync(for item: ClipboardItem) async -> Data? {
        do {
            return try await ClipboardPayloadLoader.imagePNGData(for: item, blobURL: blobURL(for: item))
        } catch {
            Log.store.error("Failed to load image blob: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load a chunk of text content, reading only what's necessary
    func textChunk(for item: ClipboardItem, charCount: Int) -> TextChunkPage? {
        Self.textChunk(for: item, textURL: blobURL(for: item), charCount: charCount)
    }

    nonisolated static func textChunk(
        for item: ClipboardItem,
        textURL: URL?,
        charCount: Int
    ) -> TextChunkPage? {
        if let url = textURL, item.textFilename != nil {
            return TextChunkReader.page(for: item, textURL: url, charCount: charCount) { error in
                Log.store.error("Failed to read text chunk: \(error.localizedDescription)")
            }
        }
        return TextChunkReader.page(for: item, textURL: nil, charCount: charCount)
    }

    /// Get the total size of an item (in bytes) for UI display.
    func itemSize(for item: ClipboardItem) -> Int? {
        if let original = item.originalSizeBytes { return original }

        switch item.type {
        case .text:
            guard let filename = item.textFilename else { return item.textContent?.utf8.count }
            guard let url = blobStore.textURL(filename: filename) else {
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
