import UIKit
import os
import UniformTypeIdentifiers

@MainActor
enum IOSPasteboardItemBuilder {
    static func text(
        _ text: String,
        marker: IOSPasteboardOriginMarker
    ) -> [[String: Any]] {
        [[
            UTType.utf8PlainText.identifier: text,
            marker.pasteboardType: marker.tokenData
        ]]
    }

    static func imagePNG(
        _ data: Data,
        marker: IOSPasteboardOriginMarker
    ) -> [[String: Any]] {
        [[
            UTType.png.identifier: data,
            marker.pasteboardType: marker.tokenData
        ]]
    }

    /// Returns the new generation only when the item carrying our tag is still current. Another
    /// process can replace the pasteboard right after `setItems`; re-validating the tag between
    /// two generation reads prevents that external write from being marked handled by us.
    static func writeAndValidateCurrentGeneration(
        _ items: [[String: Any]],
        marker: IOSPasteboardOriginMarker,
        setItems: ([[String: Any]]) -> Void,
        readChangeCount: () -> Int,
        readTypes: () -> [String],
        readData: (String) -> Data?
    ) -> Int? {
        setItems(items)
        let writtenGeneration = readChangeCount()
        guard marker.matches(
            pasteboardTypes: readTypes(),
            readData: readData
        ),
        readChangeCount() == writtenGeneration else {
            return nil
        }
        return writtenGeneration
    }
}

/// iOS clip edits (pin/bookmark/tag/OCR) and payload loading — built on the shared
/// `ClipboardMutations` so edits behave like macOS and stamp `modifiedAt` for sync. App-only:
/// kept out of the lean shared `ClipStore`, which the extensions also compile.
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

    /// Search/`#tag`/`@app`-filtered, pinned-first via the shared `ClipQuery`, memoised until
    /// `items` changes — a cache hit is a tuple compare instead of a fresh filter + sort.
    /// App-only: `ClipQuery` isn't linked into the lean keyboard/share extensions.
    func filteredItems(search: String, activeTag: String?) -> [ClipboardItem] {
        if let cached = filterCache.result(query: search, tag: activeTag) {
            return cached
        }
        let visible = PendingDeletePolicy.visibleItems(items, pending: pendingDeletion)
        let result = ClipQuery.filter(visible, search: search, activeTag: activeTag)
        filterCache.store(result, query: search, tag: activeTag)
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
    ) -> TextChunkPage? {
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
        guard let marker = pasteboardOriginMarkerForWrite(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else {
            clipStoreLog.error("Cannot mark an iOS pasteboard write for this installation.")
            return false
        }

        let pasteboardItems: [[String: Any]]?
        switch item.type {
        case .text:
            if let text = await fullText(for: item) {
                pasteboardItems = IOSPasteboardItemBuilder.text(text, marker: marker)
            } else {
                pasteboardItems = nil
            }
        case .image:
            if let data = try? await ClipboardPayloadLoader.imagePNGData(for: item, blobURL: blobURL(for: item)) {
                pasteboardItems = IOSPasteboardItemBuilder.imagePNG(data, marker: marker)
            } else {
                pasteboardItems = nil
            }
        }
        guard let pasteboardItems else { return false }

        let pasteboard = UIPasteboard.general
        let writtenGeneration = IOSPasteboardItemBuilder.writeAndValidateCurrentGeneration(
            pasteboardItems,
            marker: marker,
            setItems: { pasteboard.setItems($0) },
            readChangeCount: { pasteboard.changeCount },
            readTypes: { pasteboard.types },
            readData: { pasteboard.data(forPasteboardType: $0) }
        )
        if let writtenGeneration {
            IOSForegroundRefreshCoordinator.shared.markPasteboardChangeHandled(
                writtenGeneration
            )
        }
        touch(item)
        return true
    }
}
