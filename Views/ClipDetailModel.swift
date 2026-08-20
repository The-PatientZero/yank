import AppKit
import SwiftUI

/// Paged text-loading state for a single large clip.
struct ChunkedTextState {
    var visibleText: String = ""
    var totalBytes: Int = 0
    var loadedCharCount: Int = 0
    var reachedEOF: Bool = true
    var isLoadingMore: Bool = false
    static let chunkSize = 2_000
    static let initialChars = 2_000
    var hasMore: Bool { !reachedEOF && loadedCharCount >= Self.initialChars }
}

/// Owns the focused clip's preview / OCR / tag-input state and the async loading
/// that backs it. Keeping it here lets `ClipDetailView` stay a pure renderer while
/// the coordinator drives detail actions (add tag, save image, OCR) from its key monitor.
@MainActor
@Observable
final class ClipDetailModel {
    var previewImage: NSImage?
    var chunkedText = ChunkedTextState()
    var isExtractingText = false
    var itemSize: Int?
    var showTagInput = false
    var tagInputText = ""

    private let store: ClipboardStore
    private let previewMaxPixel = 1_200

    init(store: ClipboardStore) { self.store = store }

    func reset() {
        previewImage = nil
        chunkedText = ChunkedTextState()
        isExtractingText = false
        itemSize = nil
        showTagInput = false
        tagInputText = ""
    }

    /// Load the preview for the newly focused item (resets transient state first).
    func load(_ item: ClipboardItem?) async {
        reset()
        guard let item = item else { return }
        itemSize = store.itemSize(for: item)
        switch item.type {
        case .image:
            previewImage = await loadImage(item)
        case .text:
            if item.isFileBacked {
                await loadInitialChunk(item)
            } else {
                chunkedText.visibleText = item.textContent ?? ""
                chunkedText.reachedEOF = true
            }
        }
    }

    private func loadImage(_ item: ClipboardItem) async -> NSImage? {
        guard let url = store.blobURL(for: item) else { return nil }
        guard let cg = await ThumbnailCache.shared.loadThumbnail(for: item.id, at: url, maxPixel: previewMaxPixel) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func loadInitialChunk(_ item: ClipboardItem) async {
        chunkedText.isLoadingMore = true
        let textURL = store.blobURL(for: item)
        let result = await Task.detached(priority: .userInitiated) {
            ClipboardStore.textChunk(for: item, textURL: textURL, charCount: ChunkedTextState.initialChars)
        }.value
        if let result = result {
            chunkedText.visibleText = result.text
            chunkedText.totalBytes = result.totalBytes
            chunkedText.loadedCharCount = result.text.count
            chunkedText.reachedEOF = result.reachedEOF
        }
        chunkedText.isLoadingMore = false
    }

    func loadNextChunk(_ item: ClipboardItem) async {
        guard !chunkedText.isLoadingMore && chunkedText.hasMore else { return }
        chunkedText.isLoadingMore = true
        let nextCharCount = chunkedText.loadedCharCount + ChunkedTextState.chunkSize
        let textURL = store.blobURL(for: item)
        let result = await Task.detached(priority: .userInitiated) {
            ClipboardStore.textChunk(for: item, textURL: textURL, charCount: nextCharCount)
        }.value
        if let result = result {
            chunkedText.visibleText = result.text
            chunkedText.totalBytes = result.totalBytes
            chunkedText.loadedCharCount = result.text.count
            chunkedText.reachedEOF = result.reachedEOF
        }
        chunkedText.isLoadingMore = false
    }

    func extractText(from item: ClipboardItem) async {
        // Convert on the main actor so only the Sendable CGImage crosses to the OCR task.
        guard let cgImage = previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        isExtractingText = true
        let text = await OCRService.shared.recognizeText(from: cgImage) ?? "No text found in this image."
        store.setOCRText(text, for: item)
        isExtractingText = false
    }

    func saveImageToDisk(_ item: ClipboardItem) {
        if let img = store.image(for: item) ?? previewImage { PasteController.saveImageToDisk(img) }
    }

    func copyExtractedText(_ text: String) {
        PasteController.copyTextToClipboard(text)
    }

    // MARK: - Tag input

    func beginAddTag() { showTagInput = true }

    func cancelTagInput() {
        showTagInput = false
        tagInputText = ""
    }

    func commitTag(to item: ClipboardItem) {
        let normalized = TagChip.normalize(tagInputText)
        if !normalized.isEmpty { store.addTag(normalized, to: item) }
        cancelTagInput()
    }

    func completeTag(for item: ClipboardItem) {
        guard !tagInputText.isEmpty, let first = suggestions(for: item).first else { return }
        store.addTag(first, to: item)
        cancelTagInput()
    }

    func suggestions(for item: ClipboardItem) -> [String] {
        guard !tagInputText.isEmpty else { return [] }
        return TagSuggestions.matching(searchText: "#" + tagInputText, in: store.allTags)
            .filter { !item.tags.contains($0) }
    }

    func formattedBytes(_ bytes: Int) -> String {
        // `ByteCountFormatStyle` is a Sendable, system-cached value type — no per-call allocation.
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.bytes, .kb, .mb]))
    }
}
