import UIKit
import os
import UniformTypeIdentifiers

/// iOS clip edits — pin / bookmark / tag / OCR, plus image loading — built on the
/// shared `ClipboardMutations` so they behave exactly like the Mac and stamp
/// `modifiedAt` for last-writer-wins sync. App-only: the keyboard and share
/// extensions never need these, so they stay out of the lean shared `ClipStore`.
extension ClipStore {
    func togglePin(_ item: ClipboardItem) {
        mutate { ClipboardMutations.togglePin(&$0, id: item.id) }
    }

    func toggleBookmark(_ item: ClipboardItem) {
        mutate { ClipboardMutations.toggleBookmark(&$0, id: item.id) }
    }

    func addTag(_ tag: String, to item: ClipboardItem) {
        mutate { ClipboardMutations.addTag(tag, id: item.id, in: &$0) }
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        mutate { ClipboardMutations.removeTag(tag, id: item.id, in: &$0) }
    }

    func setOCRText(_ text: String, for item: ClipboardItem) {
        mutate { ClipboardMutations.setOCRText(text, id: item.id, in: &$0) }
    }

    var allTags: [String] {
        if let tagCache { return tagCache }
        let tags = ClipboardMutations.allTags(items)
        tagCache = tags
        return tags
    }

    /// Search / `#tag` / `@app`-filtered, pinned-first — the shared `ClipQuery`, memoised
    /// until `items` changes. The view reads this several times per render (the list plus
    /// every selection summary derived from it); on a cache hit it's a tuple compare
    /// instead of a fresh filter + sort. Lives here (app-only) because `ClipQuery` isn't
    /// linked into the lean keyboard/share extensions.
    func filteredItems(search: String, activeTag: String?) -> [ClipboardItem] {
        if let cache = filterCache, cache.query == search, cache.tag == activeTag {
            return cache.result
        }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pendingDeletion)
        let result = ClipQuery.filter(visible, search: search, activeTag: activeTag)
        filterCache = (search, activeTag, result)
        return result
    }

    // MARK: - Batch edits (multi-select)

    func setPinned(_ pinned: Bool, for items: [ClipboardItem]) {
        let ids = Set(items.map(\.id))
        mutate { ClipboardMutations.setPinned(pinned, ids: ids, in: &$0) }
    }

    func setBookmarked(_ bookmarked: Bool, for items: [ClipboardItem]) {
        let ids = Set(items.map(\.id))
        mutate { ClipboardMutations.setBookmarked(bookmarked, ids: ids, in: &$0) }
    }

    /// Share payload for a selection — full text and decoded images, ready for a
    /// `UIActivityViewController`. Clips that can't be materialised are skipped.
    func shareItems(for items: [ClipboardItem]) async -> [Any] {
        var payload: [Any] = []
        for item in items {
            switch item.type {
            case .text:
                if let text = await fullText(for: item) { payload.append(text) }
            case .image:
                if let url = blobURL(for: item) { payload.append(url) }
            }
        }
        return payload
    }

    /// Full text for a clip — the file-backed blob for large clips, else the inline content.
    func fullText(for item: ClipboardItem) async -> String? {
        do {
            return try await ClipboardPayloadLoader.fullText(for: item, blobURL: blobURL(for: item))
        } catch {
            clipStoreLog.error("Failed to load full text for clip: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func textChunk(
        for item: ClipboardItem,
        textURL: URL?,
        charCount: Int
    ) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        if let textURL, item.textFilename != nil {
            return TextChunkReader.page(for: item, textURL: textURL, charCount: charCount) { error in
                clipStoreLog.error("Failed to read iOS text chunk: \(error.localizedDescription)")
            }
        }
        return TextChunkReader.page(for: item, textURL: nil, charCount: charCount)
    }

    func itemSize(for item: ClipboardItem) -> Int? {
        if let original = item.originalSizeBytes { return original }
        switch item.type {
        case .text:
            guard item.textFilename != nil, let url = blobURL(for: item) else {
                return item.textContent?.utf8.count
            }
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        case .image:
            guard let url = blobURL(for: item) else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        }
    }

    /// Put a clip on the system pasteboard (text or image) and float it to the top.
    @discardableResult
    func copyToPasteboard(_ item: ClipboardItem) async -> Bool {
        let didCopy: Bool
        switch item.type {
        case .text:
            if let text = await fullText(for: item) {
                UIPasteboard.general.string = text
                didCopy = true
            } else {
                didCopy = false
            }
        case .image:
            if let data = try? await ClipboardPayloadLoader.imagePNGData(for: item, blobURL: blobURL(for: item)) {
                UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
                didCopy = true
            } else {
                didCopy = false
            }
        }
        if didCopy { touch(item) }
        return didCopy
    }
}
