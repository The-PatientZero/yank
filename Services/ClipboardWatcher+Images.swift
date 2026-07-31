import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

extension ClipboardWatcher {
    /// Check if a file path points to an image by examining its UTType
    nonisolated static func isImageFile(_ filePath: String) -> Bool {
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }

        if let utType = UTType(filenameExtension: fileExtension) {
            return utType.conforms(to: .image)
        }
        return false
    }

    struct ImageFileCapture: Sendable {
        let pngData: Data
    }

    /// Read image file from disk and normalize to PNG. Runs off the main actor.
    nonisolated static func imageFileCapture(_ filePath: String) -> ImageFileCapture? {
        do {
            let fileURL = URL(fileURLWithPath: filePath)
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
                Log.capture.error("Skipping non-regular image file from pasteboard file list")
                return nil
            }
            if let size = resourceValues.fileSize, size > Self.maxImageInputBytes {
                Log.capture.error("Skipping oversized image file from pasteboard file list")
                return nil
            }
            let fileData = try Data(contentsOf: fileURL)

            guard let pngData = Self.normalizedPNGData(
                from: fileData,
                maxInputBytes: Self.maxImageInputBytes,
                maxRasterPixels: Self.maxRasterPixels,
                sourceDescription: filePath
            ) else {
                Log.capture.error("Failed to convert image file from pasteboard file list")
                return nil
            }

            return ImageFileCapture(pngData: pngData)
        } catch {
            Log.capture.error("Error processing image file from pasteboard file list: \(error.localizedDescription)")
            return nil
        }
    }

    /// Normalise arbitrary raster bytes to PNG using a single `CGImageSource` for both the
    /// pixel-budget check and the re-encode: no TIFF/bitmap round-trip, one
    /// decode, no uncompressed-bitmap allocation. Off the main actor.
    nonisolated static func normalizedPNGData(
        from data: Data,
        maxInputBytes: Int,
        maxOutputBytes: Int = SyncBlobKind.image.maximumBytes,
        maxRasterPixels: Int64,
        sourceDescription: String,
        encoder: @Sendable (CGImage) -> Data? = PNGEncoder.encode
    ) -> Data? {
        guard data.count <= maxInputBytes else {
            Log.capture.error("Skipping oversized image data: \(sourceDescription)")
            return nil
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        guard pixelCountIsWithinBudget(source, maxRasterPixels: maxRasterPixels) else {
            Log.capture.error("Skipping image with too many pixels: \(sourceDescription)")
            return nil
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let pngData = encoder(cgImage),
              !pngData.isEmpty,
              pngData.count <= maxOutputBytes else {
            Log.capture.error("Skipping image whose normalized PNG exceeds the byte budget: \(sourceDescription)")
            return nil
        }
        return pngData
    }

    nonisolated static func normalizedImagePayload(
        from data: Data,
        richArchive: PasteboardArchive?,
        limits: PasteboardPayloadMaterializer.Limits,
        maxRasterPixels: Int64,
        sourceDescription: String,
        encoder: @Sendable (CGImage) -> Data? = PNGEncoder.encode
    ) -> PasteboardPayload {
        guard let pngData = normalizedPNGData(
            from: data,
            maxInputBytes: limits.maxImageBytes,
            maxOutputBytes: limits.maxImageBytes,
            maxRasterPixels: maxRasterPixels,
            sourceDescription: sourceDescription,
            encoder: encoder
        ) else {
            return .unsupported
        }
        let archiveBytes = richArchive?.totalBytes ?? 0
        guard archiveBytes <= limits.maxPayloadBytes,
              pngData.count <= limits.maxPayloadBytes - archiveBytes else {
            Log.capture.error("Skipping normalized image whose retained payload exceeds the aggregate byte budget")
            return .unsupported
        }
        return .image(pngData, richArchive: richArchive)
    }

    /// True when the first image in `source` is within the pixel budget. Lenient when the
    /// dimensions can't be read (no properties / zero size) — defers the reject to the
    /// decode step, preserving the previous fail-open behaviour for odd encodings.
    private nonisolated static func pixelCountIsWithinBudget(
        _ source: CGImageSource,
        maxRasterPixels: Int64
    ) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return true
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return true }
        return Int64(width) * Int64(height) <= maxRasterPixels
    }
}
