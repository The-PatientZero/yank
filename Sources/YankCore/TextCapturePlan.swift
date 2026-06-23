import Foundation

/// Pure capture decision for plain text clips.
///
/// The AppKit watcher owns pasteboard access; this policy owns the CPU-heavy work
/// derived from the captured string: byte counting, fingerprinting, previews, truncation,
/// and the file-backed search index. It is intentionally Foundation-only so it can be
/// tested in `YankCore` and shared by future capture surfaces.
struct TextCapturePlan: Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case inline(String)
        case fileBacked(preview: String, fullText: String, originalSizeBytes: Int, searchIndex: String?)
        case truncated(preview: String, originalSizeBytes: Int)
    }

    let fingerprint: ClipboardContentFingerprint
    let byteCount: Int
    let storage: Storage

    static func make(
        for text: String,
        inlineLimit: Int,
        previewLength: Int,
        maxStoredBytes: Int
    ) -> TextCapturePlan {
        let byteCount = text.utf8.count
        let fingerprint = ClipboardContentFingerprint.text(text)
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

        return TextCapturePlan(fingerprint: fingerprint, byteCount: byteCount, storage: storage)
    }
}
