import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSImage {
    /// Encodes the image as PNG data, or `nil` if the backing `CGImage` is unavailable.
    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return PNGEncoder.encode(cgImage)
    }
}

/// Encodes a `CGImage` to PNG via `CGImageDestination`, skipping the TIFF/bitmap round-trip
/// (no extra allocation, no double-decode). Centralised here so capture, paste, and
/// save-to-disk share the one allocation-light path.
enum PNGEncoder {
    static func encode(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
