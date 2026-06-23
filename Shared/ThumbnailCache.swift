import Foundation
import CoreGraphics
import ImageIO

/// A bounded, shared cache of downsampled thumbnails decoded straight off disk via
/// ImageIO — so scrolling a grid never re-decodes (or full-resolution decodes) the same
/// blob. Stores platform-neutral `CGImage`; the macOS/iOS thumbnail views wrap it into
/// `NSImage`/`UIImage`. Keyed by the immutable blob identity + the requested pixel size
/// (a clip's image never changes for a given id, so entries never go stale). `NSCache`
/// is thread-safe and evicts under memory pressure on its own; the count limit is a backstop.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, CGImage>()

    private init() { cache.countLimit = 200 }

    /// Returns the cached thumbnail on a hit; otherwise decodes a downsampled copy
    /// (callers already hop to a background task) and stores it. `maxPixel` is the
    /// longest edge in pixels.
    func thumbnail(for id: UUID, at url: URL, maxPixel: Int) -> CGImage? {
        let key = "\(id.uuidString)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = Self.downsample(url: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func loadThumbnail(for id: UUID, at url: URL, maxPixel: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            ThumbnailCache.shared.thumbnail(for: id, at: url, maxPixel: maxPixel)
        }.value
    }

    func clear() { cache.removeAllObjects() }

    /// Decode a thumbnail directly at the target size — ImageIO never materialises the
    /// full-resolution bitmap, so a 12-MP photo costs ~the thumbnail, not ~48 MB.
    private static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
