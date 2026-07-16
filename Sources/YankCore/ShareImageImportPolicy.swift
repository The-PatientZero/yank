import Foundation

/// Pure limits for images accepted through the iOS share extension.
enum ShareImageImportPolicy {
    enum SourceFileError: Error, Equatable {
        case invalidFile
        case tooLarge
    }

    static let maxDownsampledPixel = 2_048
    static let maxInMemoryImageBytes = SyncBlobKind.image.maximumBytes
    /// Encoded provider files may be larger than the final normalized PNG, but must be
    /// rejected before copying so an extension never duplicates an unbounded file.
    static let maxEncodedSourceFileBytes = 64 * 1_024 * 1_024

    static func acceptsInMemoryPayload(byteCount: Int) -> Bool {
        (0...maxInMemoryImageBytes).contains(byteCount)
    }

    static func acceptsEncodedSourceFile(byteCount: Int) -> Bool {
        (1...maxEncodedSourceFileBytes).contains(byteCount)
    }

    @discardableResult
    static func validateEncodedSourceFile(at url: URL) throws -> Int {
        guard url.isFileURL else { throw SourceFileError.invalidFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            throw SourceFileError.invalidFile
        }
        guard acceptsEncodedSourceFile(byteCount: fileSize) else {
            throw SourceFileError.tooLarge
        }
        return fileSize
    }
}
