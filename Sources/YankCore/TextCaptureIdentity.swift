import Foundation

/// Conservative duplicate identity for durable text history: only complete, plain, inline
/// text is eligible. File-backed, truncated, and rich captures stay distinct because their
/// persisted preview isn't the full payload, or their paste behaviour carries more than the string.
enum TextCaptureIdentity {
    static func matches(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        guard isEligible(lhs), isEligible(rhs),
              let lhsText = lhs.textContent,
              let rhsText = rhs.textContent,
              lhsText.utf8.count == rhsText.utf8.count else {
            return false
        }
        return lhsText.utf8.elementsEqual(rhsText.utf8)
    }

    private static func isEligible(_ item: ClipboardItem) -> Bool {
        item.type == .text
            && item.textFilename == nil
            && !item.isTruncated
            && item.richFilename == nil
            && !item.hasRichContent
            && item.textContent != nil
    }
}
