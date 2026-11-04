import UIKit
import UniformTypeIdentifiers

/// Reads a clipboard or Shortcuts image as the downsampled PNG every image clip is stored as,
/// within the same limits as images saved from the share sheet.
enum PasteboardImageReader {
    enum Result: Equatable, Sendable {
        case png(Data)
        /// Nothing came back, which is how a denied paste looks. Worth trying again later.
        case unreadable
        /// Too large or not a decodable image. Trying again cannot help.
        case unsupported
    }

    /// Reads the first declared image type. Only one read, so a paste prompt appears once.
    @MainActor
    static func read(from pasteboard: UIPasteboard, types: [String]) async -> Result {
        guard let imageType = types.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            return .unsupported
        }
        guard let data = pasteboard.data(forPasteboardType: imageType) else { return .unreadable }
        return await normalize(data)
    }

    /// Checks the file's size before decoding, so a huge file is never loaded into memory.
    static func normalize(fileAt url: URL) async -> Result {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try ShareImageImportPolicy.validateEncodedSourceFile(at: url)
        } catch {
            return .unsupported
        }
        let png = await Task.detached(priority: .userInitiated) {
            PNGDownsampler.png(fromFileAt: url, maxPixel: ShareImageImportPolicy.maxDownsampledPixel)
        }.value
        return validated(png)
    }

    static func normalize(_ encoded: Data) async -> Result {
        guard ShareImageImportPolicy.acceptsEncodedSourceFile(byteCount: encoded.count) else {
            return .unsupported
        }
        let png = await Task.detached(priority: .userInitiated) {
            PNGDownsampler.png(from: encoded, maxPixel: ShareImageImportPolicy.maxDownsampledPixel)
        }.value
        return validated(png)
    }

    private static func validated(_ png: Data?) -> Result {
        guard let png, !png.isEmpty, ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: png.count) else {
            return .unsupported
        }
        return .png(png)
    }
}
