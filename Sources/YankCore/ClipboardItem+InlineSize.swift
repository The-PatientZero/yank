import Foundation

extension ClipboardItem {
    /// The clip's size when it can be told without touching a file: the recorded original size,
    /// else the byte count of text held inline. A file-backed clip's preview text is never its
    /// size, so those return nil and each platform reads the file itself.
    var inlineSizeBytes: Int? {
        if let originalSizeBytes { return originalSizeBytes }
        guard type == .text, textFilename == nil else { return nil }
        return textContent?.utf8.count
    }
}
