import Foundation

/// Pure limits for images accepted through the iOS share extension.
enum ShareImageImportPolicy {
    static let maxDownsampledPixel = 2_048
    static let maxInMemoryImageBytes = SyncBlobKind.image.maximumBytes

    static func acceptsInMemoryPayload(byteCount: Int) -> Bool {
        (0...maxInMemoryImageBytes).contains(byteCount)
    }
}
