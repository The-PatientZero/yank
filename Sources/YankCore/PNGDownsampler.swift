import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an encoded image into a PNG whose longest edge is at most `maxPixel`, applying the
/// image's orientation. ImageIO decodes straight to the smaller size, so a large photo never
/// sits in memory at full resolution. Used by every iOS path that saves an image clip.
enum PNGDownsampler {
    static func png(fromFileAt url: URL, maxPixel: Int) -> Data? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return png(from: source, maxPixel: maxPixel)
    }

    static func png(from data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        return png(from: source, maxPixel: maxPixel)
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func png(from source: CGImageSource, maxPixel: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
