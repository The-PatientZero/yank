import Foundation

/// Pure capture decision for plain text clips: the AppKit watcher owns pasteboard access,
/// this policy owns the CPU-heavy derived work (byte counting, previews, truncation, search
/// index). Foundation-only, so it's testable in `YankCore` and reusable by future capture surfaces.
struct TextCapturePlan: Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case inline(String)
        case fileBacked(preview: String, fullText: String, originalSizeBytes: Int, searchIndex: String?)
        case truncated(preview: String, originalSizeBytes: Int)
    }

    let byteCount: Int
    let storage: Storage

    static func make(
        for text: String,
        inlineLimit: Int,
        previewLength: Int,
        maxStoredBytes: Int
    ) -> TextCapturePlan {
        let byteCount = text.utf8.count
        let preview = String(text.prefix(previewLength))

        let storage: Storage
        if byteCount <= inlineLimit {
            storage = .inline(text)
        } else if byteCount <= maxStoredBytes {
            storage = .fileBacked(
                preview: preview,
                fullText: text,
                originalSizeBytes: byteCount,
                searchIndex: ClipboardSearchIndex.make(for: text)
            )
        } else {
            storage = .truncated(preview: preview, originalSizeBytes: byteCount)
        }

        return TextCapturePlan(byteCount: byteCount, storage: storage)
    }
}
