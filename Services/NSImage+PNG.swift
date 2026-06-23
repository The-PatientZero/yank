import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSImage {
    /// Encode the image as PNG `Data`. Re-encodes straight from the backing `CGImage` via
    /// `CGImageDestination` instead of round-tripping through an uncompressed TIFF/bitmap
    /// representation, so it neither allocates a full uncompressed bitmap nor double-decodes.
    /// The single conversion path shared by paste and save-to-disk.
    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return PNGEncoder.encode(cgImage)
    }
}

/// PNG encoding from a `CGImage` via ImageIO. Centralised so capture, paste, and
/// save-to-disk share one allocation-light path.
enum PNGEncoder {
    /// Encode a decoded image to PNG `Data`.
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
