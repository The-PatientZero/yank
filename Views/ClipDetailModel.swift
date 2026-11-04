import AppKit
import SwiftUI

/// Owns the focused clip's preview / OCR / tag-input state and the async loading
/// that backs it. Keeping it here lets `ClipDetailView` stay a pure renderer while
/// the coordinator drives detail actions (add tag, save image, OCR) from its key monitor.
@MainActor
@Observable
final class ClipDetailModel {
    var previewImage: NSImage?
    var chunkedText = ChunkedTextPaging()
    var isExtractingText = false
    /// The clip whose last extraction found no usable text; cleared when focus moves or a new run starts.
    private(set) var noTextFoundItemID: UUID?
    var itemSize: Int?
    var showTagInput = false
    var tagInputText = ""

    private let store: ClipboardStore
    private let previewMaxPixel = 1_200
    /// Identifies the extraction run whose result may still update the UI; `reset()` invalidates it.
    private var activeExtractionRun: UUID?

    /// Shown (and announced) when text recognition returns nothing, including when it failed.
    static let noTextFoundMessage = "Couldn't read any text from this image."

    init(store: ClipboardStore) { self.store = store }

    func reset() {
        previewImage = nil
        chunkedText = ChunkedTextPaging()
        isExtractingText = false
        noTextFoundItemID = nil
        activeExtractionRun = nil
        itemSize = nil
        showTagInput = false
        tagInputText = ""
    }

    /// Load the preview for the newly focused item (resets transient state first).
    /// `beginTagInput` opens the tag field in the same step as the reset, before any await, so
    /// the field exists on the first frame and a slow load can never open it for another clip.
    func load(_ item: ClipboardItem?, beginTagInput: Bool = false) async {
        reset()
        showTagInput = beginTagInput
        guard let item = item else { return }
        chunkedText.begin(itemID: item.id)
        itemSize = store.itemSize(for: item)
        switch item.type {
        case .image:
            let image = await loadImage(item)
            // A late preview must not replace the newly focused clip's.
            guard !Task.isCancelled, chunkedText.itemID == item.id else { return }
            previewImage = image
        case .text:
            if item.isFileBacked {
                await loadInitialChunk(item)
            } else {
                chunkedText.showInline(item.textContent ?? "")
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
        guard let request = chunkedText.firstRequest() else { return }
        await read(request, of: item)
    }

    func loadNextChunk(_ item: ClipboardItem) async {
        guard let request = chunkedText.nextRequest() else { return }
        await read(request, of: item)
    }

    /// Reads one page off the main thread and hands it back; the paging state drops a page that
    /// arrives after focus moved to another clip.
    private func read(_ request: ChunkedTextPaging.Request, of item: ClipboardItem) async {
        let textURL = store.blobURL(for: item)
        let page = await Task.detached(priority: .userInitiated) {
            ClipboardStore.textChunk(
                for: item,
                textURL: textURL,
                charCount: request.charCount,
                byteOffset: request.byteOffset
            )
        }.value
        chunkedText.apply(page, for: request.itemID, at: request.byteOffset)
    }

    func extractText(from item: ClipboardItem) async {
        // Convert on the main actor so only the Sendable CGImage crosses to the OCR task.
        guard let cgImage = previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let run = UUID()
        activeExtractionRun = run
        isExtractingText = true
        noTextFoundItemID = nil
        let text = await OCRService.shared.recognizeText(from: cgImage)
        // Usable text is stored for the clip it was read from even if focus has moved on.
        store.setOCRText(text, for: item)
        // Focus moving to another clip reset this state already; a late result must not restore it.
        guard activeExtractionRun == run else { return }
        activeExtractionRun = nil
        isExtractingText = false
        if text.map(ClipboardItem.isUsableOCRText) != true {
            noTextFoundItemID = item.id
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: Self.noTextFoundMessage, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
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
        let normalized = TagNormalization.normalize(tagInputText)
        if !normalized.isEmpty { store.addTag(normalized, to: item) }
        cancelTagInput()
    }

    func completeTag(for item: ClipboardItem) {
        guard !tagInputText.isEmpty, let first = suggestions(for: item).first else { return }
        store.addTag(first, to: item)
        cancelTagInput()
    }

    func suggestions(for item: ClipboardItem) -> [String] {
        TagSuggestions.suggestions(forInput: tagInputText, in: store.allTags, excluding: item.tags)
    }

    func formattedBytes(_ bytes: Int) -> String {
        // `ByteCountFormatStyle` is a Sendable, system-cached value type — no per-call allocation.
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.bytes, .kb, .mb]))
    }
}
