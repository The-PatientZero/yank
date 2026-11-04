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

    /// Text up to this many UTF-8 bytes stays inline in the history record; larger text is
    /// file-backed. Both platforms capture under this policy, which keeps one huge clip from
    /// bloating in-memory history (critical for the memory-constrained keyboard extension) and
    /// the synced `textContent` field.
    static let inlineLimit = 50_000
    /// Characters kept as the stored preview of file-backed and oversized text. The preview has
    /// been this length in every released build, so notes about it hold for older clips too.
    static let previewLength = 500

    let byteCount: Int
    let storage: Storage

    /// The capture policy both platforms use: the shared inline limit and preview length, and the
    /// blob ceiling above which text is truncated.
    static func make(for text: String) -> TextCapturePlan {
        make(
            for: text,
            inlineLimit: inlineLimit,
            previewLength: previewLength,
            maxStoredBytes: SyncBlobKind.text.maximumBytes
        )
    }

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
