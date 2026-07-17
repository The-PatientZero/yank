import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@MainActor
final class ShareViewController: UIViewController {
    private let appGroup = AppGroupContainer.live()

    private static let confirmationDuration: Duration = .milliseconds(800)
    private static let failureDuration: Duration = .milliseconds(1400)
    private static let voiceOverExtraDuration: Duration = .milliseconds(600)

    enum ShareError: Error, LocalizedError {
        case storageUnavailable
        case unsupportedContent
        case malformedItem
        case imageTooLarge
        case imageWriteFailed
        case captureQueueFull
        case textTooLarge

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Yank's shared storage is unavailable. " +
                    "Open Yank to check its status, then try again."
            case .unsupportedContent: return "The shared item isn't text, a URL, or an image."
            case .malformedItem: return "The shared item couldn't be read."
            case .imageTooLarge: return "The shared image is too large to save."
            case .imageWriteFailed: return "The shared image couldn't be saved."
            case .captureQueueFull: return "Yank has pending shared items. Open the app, then try again."
            case .textTooLarge: return "The shared text is too large to save."
            }
        }
    }

    private enum SharedContent {
        case text(String)
        case image(Data)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await run() }
    }

    // MARK: - Pipeline
    private func run() async {
        guard let appGroup else {
            let error = ShareError.storageUnavailable
            present(.failed(reason: error.errorDescription))
            await holdForFailure()
            extensionContext?.cancelRequest(withError: error)
            return
        }

        do {
            let content = try await sharedContent()
            let excerpt: String
            switch content {
            case let .text(text):
                try await enqueue(text: text, in: appGroup.shareInbox)
                excerpt = self.excerpt(of: text)
            case let .image(pngData):
                try await enqueue(imagePNG: pngData, in: appGroup.shareInbox)
                excerpt = "Image"
            }
            IOSMotion.successFeedback()
            let outcome = ShareConfirmationView.Outcome.saved(excerpt: excerpt)
            present(outcome)
            postAccessibilityAnnouncement(for: outcome)
            try? await Task.sleep(for: Self.confirmationDuration)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            let outcome = ShareConfirmationView.Outcome.failed(reason: localizedReason(for: error))
            present(outcome)
            postAccessibilityAnnouncement(for: outcome)
            await holdForFailure()
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func holdForFailure() async {
        let extra: Duration = UIAccessibility.isVoiceOverRunning ? Self.voiceOverExtraDuration : .zero
        try? await Task.sleep(for: Self.failureDuration + extra)
    }

    private func localizedReason(for error: Error) -> String? {
        if let shareError = error as? ShareError { return shareError.errorDescription }
        return (error as NSError).localizedDescription
    }

    private func postAccessibilityAnnouncement(for outcome: ShareConfirmationView.Outcome) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let message: String
        switch outcome {
        case let .saved(excerpt) where !excerpt.isEmpty: message = "Saved to Yank. \(excerpt)"
        case .saved: message = "Saved to Yank"
        case let .failed(reason?): message = "Couldn't save. \(reason)"
        case .failed: message = "Couldn't save to Yank"
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func sharedContent() async throws -> SharedContent {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = extensionItem.attachments?.first else {
            throw ShareError.unsupportedContent
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return .image(try await loadImagePNG(from: provider))
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return .text(
                try await provider.loadText(forTypeIdentifier: UTType.plainText.identifier) {
                    $0 as? String
                }
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return .text(
                try await provider.loadText(forTypeIdentifier: UTType.url.identifier) {
                    ($0 as? URL)?.absoluteString
                }
            )
        }
        throw ShareError.unsupportedContent
    }

    private nonisolated func loadImagePNG(from provider: NSItemProvider) async throws -> Data {
        if let fileURL = try await provider.loadTemporaryImageFileRepresentation(
            forTypeIdentifier: UTType.image.identifier
        ) {
            defer { Self.removeTemporaryImageFile(at: fileURL) }
            return try await Self.downsampledPNGFromFile(at: fileURL)
        }

        let source = try await provider.loadImageSource(forTypeIdentifier: UTType.image.identifier)
        switch source {
        case let .temporaryFile(fileURL):
            defer { Self.removeTemporaryImageFile(at: fileURL) }
            return try await Self.downsampledPNGFromFile(at: fileURL)
        case let .encodedData(data):
            guard ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: data.count) else {
                throw ShareError.imageTooLarge
            }
            return try await Self.downsampledPNGFromData(data)
        case let .downsampledPNG(pngData):
            return try Self.validatedPNGData(pngData)
        }
    }

    private nonisolated static func downsampledPNGFromFile(at url: URL) async throws -> Data {
        let pngData = await Task.detached(priority: .userInitiated) {
            Self.downsampledPNG(fromFileAt: url, maxPixel: ShareImageImportPolicy.maxDownsampledPixel)
        }.value
        return try Self.validatedPNGData(pngData)
    }

    private nonisolated static func downsampledPNGFromData(_ data: Data) async throws -> Data {
        let pngData = await Task.detached(priority: .userInitiated) {
            Self.downsampledPNG(from: data, maxPixel: ShareImageImportPolicy.maxDownsampledPixel)
        }.value
        return try Self.validatedPNGData(pngData)
    }

    fileprivate nonisolated static func downsampledPNG(from image: UIImage, maxPixel: Int) -> Data? {
        let pixelSize = Self.pixelSize(of: image)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        let longestEdge = max(pixelSize.width, pixelSize.height)
        let scale = min(1, CGFloat(maxPixel) / longestEdge)
        let targetSize = CGSize(
            width: max(1, (pixelSize.width * scale).rounded()),
            height: max(1, (pixelSize.height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private nonisolated static func pixelSize(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        if let ciImage = image.ciImage {
            return ciImage.extent.size
        }
        let scale = max(image.scale, 1)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private nonisolated static func downsampledPNG(fromFileAt url: URL, maxPixel: Int) -> Data? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }
        return downsampledPNG(from: source, maxPixel: maxPixel)
    }

    private nonisolated static func downsampledPNG(from data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return downsampledPNG(from: source, maxPixel: maxPixel)
    }

    private nonisolated static func downsampledPNG(from source: CGImageSource, maxPixel: Int) -> Data? {
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

    fileprivate nonisolated static func validatedPNGData(_ data: Data?) throws -> Data {
        guard let data else { throw ShareError.malformedItem }
        guard ShareImageImportPolicy.acceptsInMemoryPayload(byteCount: data.count) else {
            throw ShareError.imageTooLarge
        }
        return data
    }

    private nonisolated static func removeTemporaryImageFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func excerpt(of text: String) -> String {
        ClipboardItem.text(text).excerpt
    }

    private func present(_ outcome: ShareConfirmationView.Outcome) {
        let host = UIHostingController(rootView: ShareConfirmationView(outcome: outcome))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private extension ShareViewController {
    func enqueue(text: String, in inbox: ShareCaptureInbox) async throws {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try inbox.enqueue(text: text, sourceApp: "Share")
            }.value
        } catch ShareCaptureInbox.Error.quotaExceeded {
            throw ShareError.captureQueueFull
        } catch ShareCaptureInbox.Error.textTooLarge {
            throw ShareError.textTooLarge
        } catch {
            throw ShareError.storageUnavailable
        }
    }

    func enqueue(imagePNG: Data, in inbox: ShareCaptureInbox) async throws {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try inbox.enqueue(imagePNG: imagePNG, sourceApp: "Share")
            }.value
        } catch ShareCaptureInbox.Error.quotaExceeded {
            throw ShareError.captureQueueFull
        } catch ShareCaptureInbox.Error.payloadTooLarge {
            throw ShareError.imageTooLarge
        } catch {
            throw ShareError.imageWriteFailed
        }
    }
}

private enum ProviderImageSource: Sendable {
    case temporaryFile(URL)
    case encodedData(Data)
    case downsampledPNG(Data)
}

private extension NSItemProvider {
    func loadText(
        forTypeIdentifier identifier: String,
        extract: @escaping @Sendable (NSSecureCoding?) -> String?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let text = extract(value) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                }
            }
        }
    }

    func loadTemporaryImageFileRepresentation(forTypeIdentifier identifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    continuation.resume(returning: try Self.copyTemporaryImageFile(at: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadImageSource(forTypeIdentifier identifier: String) async throws -> ProviderImageSource {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch value {
                case let url as URL:
                    guard url.isFileURL else {
                        continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                        return
                    }
                    do {
                        continuation.resume(
                            returning: .temporaryFile(try Self.copyTemporaryImageFile(at: url))
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case let data as Data:
                    continuation.resume(returning: .encodedData(data))
                case let image as UIImage:
                    guard let data = ShareViewController.downsampledPNG(
                        from: image,
                        maxPixel: ShareImageImportPolicy.maxDownsampledPixel
                    ) else {
                        continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                        return
                    }
                    continuation.resume(returning: .downsampledPNG(data))
                default:
                    continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                }
            }
        }
    }

    private static func copyTemporaryImageFile(at url: URL) throws -> URL {
        do {
            try ShareImageImportPolicy.validateEncodedSourceFile(at: url)
        } catch ShareImageImportPolicy.SourceFileError.tooLarge {
            throw ShareViewController.ShareError.imageTooLarge
        } catch {
            throw ShareViewController.ShareError.malformedItem
        }

        let pathExtension = url.pathExtension.isEmpty ? "image" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("yank-share-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
