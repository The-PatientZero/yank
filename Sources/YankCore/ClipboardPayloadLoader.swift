import Foundation

enum ClipboardPayloadLoader {
    enum Error: Swift.Error, Equatable {
        case missingContent
        case missingBlob
        case invalidTextEncoding
        case notImage
        case invalidArchive
    }

    static func fullText(for item: ClipboardItem, blobURL: URL?) async throws -> String {
        guard item.type == .text else { throw Error.missingContent }
        guard item.textFilename != nil else {
            guard let text = item.textContent else { throw Error.missingContent }
            return text
        }
        guard let blobURL else { throw Error.missingBlob }
        let data = try await SyncBlobStorage.read(from: blobURL, maxBytes: SyncBlobKind.text.maximumBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw Error.invalidTextEncoding }
        return text
    }

    static func imagePNGData(for item: ClipboardItem, blobURL: URL?) async throws -> Data {
        guard item.type == .image else { throw Error.notImage }
        guard let blobURL else { throw Error.missingBlob }
        return try await SyncBlobStorage.read(from: blobURL, maxBytes: SyncBlobKind.image.maximumBytes)
    }

    static func richArchive(for item: ClipboardItem, blobURL: URL?) async throws -> PasteboardArchive {
        guard item.richFilename != nil else { throw Error.missingContent }
        guard let blobURL else { throw Error.missingBlob }
        let data = try await SyncBlobStorage.read(from: blobURL, maxBytes: SyncBlobKind.rich.maximumBytes)
        do {
            return try PropertyListDecoder().decode(PasteboardArchive.self, from: data)
        } catch {
            throw Error.invalidArchive
        }
    }
}
