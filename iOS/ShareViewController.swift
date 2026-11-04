import ImageIO
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let appGroup = AppGroupContainer.live()

    private static let confirmationDuration: Duration = .milliseconds(800)
    /// Clips saved from one share. The rest are named on the card so they can be shared again.
    nonisolated static let maxClipsPerShare = 10
    private nonisolated static let log = Logger(subsystem: "com.thepatientzero.yank", category: "share")

    enum ShareError: Error, LocalizedError {
        case storageUnavailable
        case unsupportedContent
        case malformedItem
        case imageTooLarge
        case imageWriteFailed
        case captureQueueFull
        case textTooLarge
        case emptyText
        case fileNotSupported
        case tooManyItems

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
            case .emptyText: return "There is no text to save."
            case .fileNotSupported: return "Yank can't save files. Share the text or an image instead."
            case .tooManyItems:
                return "Yank saves up to \(ShareViewController.maxClipsPerShare) items from one share."
            }
        }
    }

    /// One thing to save, numbered in the order shared. Text is read up front because it is small
    /// and duplicates must be dropped before the limit applies; an image is read only when its turn
    /// comes, one at a time, to stay inside the extension's memory limit.
    private enum ShareSlot {
        case text(String)
        case image(NSItemProvider)
        case unreadable(Error)
    }

    private var hostingController: UIHostingController<ShareConfirmationView>?
    private var dismissalContinuation: CheckedContinuation<Void, Never>?
    private var didDismiss = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await run() }
    }

    /// The host closes the extension (for example a swipe down on the sheet) without the Done button.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        finishDismissal()
    }

    // MARK: - Pipeline
    private func run() async {
        guard let appGroup else {
            await finishWithFailure(ShareError.storageUnavailable)
            return
        }

        let slots: [ShareSlot]
        do {
            slots = try await shareSlots()
        } catch {
            await finishWithFailure(error)
            return
        }

        let attempted = slots.prefix(Self.maxClipsPerShare)
        var savedCount = 0
        var lastExcerpt = ""
        var failures: [(position: Int, error: Error)] = []
        for (index, slot) in attempted.enumerated() {
            let position = index + 1
            // A full queue fails every remaining clip the same way; do not read them to find out.
            if let blocked = failures.first(where: { ($0.error as? ShareError) == .captureQueueFull }) {
                failures.append((position, blocked.error))
                continue
            }
            do {
                lastExcerpt = try await save(slot, in: appGroup.shareInbox)
                savedCount += 1
            } catch {
                if !(error is ShareError) { Self.logFailure("Reading a shared item", error) }
                failures.append((position, error))
            }
        }
        let notTried = slots.count > Self.maxClipsPerShare
            ? Array((Self.maxClipsPerShare + 1)...slots.count)
            : []

        if failures.isEmpty, notTried.isEmpty {
            IOSMotion.successFeedback()
            let excerpt = savedCount == 1 ? lastExcerpt : "\(savedCount) items"
            let outcome = ShareConfirmationView.Outcome.saved(excerpt: excerpt)
            present(outcome)
            postAccessibilityAnnouncement(for: outcome)
            try? await Task.sleep(for: Self.confirmationDuration)
            extensionContext?.completeRequest(returningItems: nil)
        } else if savedCount == 0 {
            await finishWithFailure(failures.first?.error ?? ShareError.tooManyItems)
        } else {
            await finishPartially(
                saved: savedCount,
                total: slots.count,
                notSaved: failures.map(\.position) + notTried,
                firstError: failures.first?.error ?? ShareError.tooManyItems
            )
        }
    }

    /// Saves one slot and returns the short text the success card shows for it.
    private func save(_ slot: ShareSlot, in inbox: ShareCaptureInbox) async throws -> String {
        switch slot {
        case let .text(text):
            try await enqueue(text: text, in: inbox)
            return excerpt(of: text)
        case let .image(provider):
            try await enqueue(imagePNG: try await loadImagePNG(from: provider), in: inbox)
            return "Image"
        case let .unreadable(error):
            throw error
        }
    }

    private func finishWithFailure(_ error: Error) async {
        let outcome = ShareConfirmationView.Outcome.failed(reason: localizedReason(for: error))
        present(outcome, onDone: { [weak self] in self?.finishDismissal() })
        postAccessibilityAnnouncement(for: outcome)
        await waitForDismissal()
        extensionContext?.cancelRequest(withError: error)
    }

    private func finishPartially(saved: Int, total: Int, notSaved: [Int], firstError: Error) async {
        let label = notSaved.count == 1 ? "item" : "items"
        let positions = notSaved.sorted().map(String.init).joined(separator: ", ")
        var reason = "Not saved: \(label) \(positions)."
        if let detail = localizedReason(for: firstError) { reason += " \(detail)" }
        let outcome = ShareConfirmationView.Outcome.partial(saved: saved, total: total, reason: reason)
        present(outcome, onDone: { [weak self] in self?.finishDismissal() })
        postAccessibilityAnnouncement(for: outcome)
        await waitForDismissal()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Returns when the user taps Done or the host dismisses the extension, whichever comes first.
    private func waitForDismissal() async {
        guard !didDismiss else { return }
        await withCheckedContinuation { dismissalContinuation = $0 }
    }

    private func finishDismissal() {
        didDismiss = true
        dismissalContinuation?.resume()
        dismissalContinuation = nil
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
        case let .partial(saved, total, reason):
            message = ShareConfirmationView.partialAnnouncement(saved: saved, total: total, reason: reason)
        case let .failed(reason?): message = "Couldn't save. \(reason)"
        case .failed: message = "Couldn't save to Yank"
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Reading the shared items
    private func shareSlots() async throws -> [ShareSlot] {
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        var seenTexts: Set<Data> = []
        var slots: [ShareSlot] = []
        for item in items {
            for slot in await chooseSlots(for: item) {
                if case let .text(text) = slot {
                    // Byte-for-byte, so two texts that only look alike are both kept.
                    guard seenTexts.insert(Data(text.utf8)).inserted else { continue }
                }
                slots.append(slot)
            }
        }
        guard !slots.isEmpty else { throw ShareError.unsupportedContent }
        return slots
    }

    /// Chooses one kind of content per shared item, a web URL before text before an image, so a page
    /// share that carries preview images saves the page address once. Text that is more than the
    /// URL itself (a selection from a web page) wins over the URL.
    private func chooseSlots(for item: NSExtensionItem) async -> [ShareSlot] {
        let providers = item.attachments ?? []
        let urlProviders = providers.filter(Self.isWebURL)
        // A provider that offers a web URL is a URL, even if it also offers a text form of it.
        let textProviders = providers.filter { !Self.isWebURL($0) && Self.textCarrier(of: $0) != nil }
        let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        if !urlProviders.isEmpty, !textProviders.isEmpty {
            let urlSlots = await loadSlots(of: urlProviders, using: loadURLString)
            let textSlots = await loadSlots(of: textProviders, using: loadTextString)
            let urlStrings = urlSlots.compactMap(Self.textValue)
            let hasTextBeyondURL = textSlots.compactMap(Self.textValue).contains { text in
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !urlStrings.contains { $0.utf8.elementsEqual(text.utf8) }
            }
            return hasTextBeyondURL ? textSlots : urlSlots
        }
        if !urlProviders.isEmpty { return await loadSlots(of: urlProviders, using: loadURLString) }
        if !textProviders.isEmpty { return await loadSlots(of: textProviders, using: loadTextString) }
        return imageProviders.map(ShareSlot.image)
    }

    private func loadSlots(
        of providers: [NSItemProvider],
        using load: @MainActor (NSItemProvider) async throws -> String
    ) async -> [ShareSlot] {
        var slots: [ShareSlot] = []
        for provider in providers {
            do {
                slots.append(.text(try await load(provider)))
            } catch {
                if !(error is ShareError) { Self.logFailure("Reading shared text", error) }
                slots.append(.unreadable(error))
            }
        }
        return slots
    }

    private static func textValue(of slot: ShareSlot) -> String? {
        if case let .text(text) = slot { return text }
        return nil
    }

    private static func isWebURL(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    private enum TextCarrier {
        case plainText(identifier: String)
        case richText(identifier: String)
    }

    /// The most readable form a provider offers: plain text, then RTF. HTML is not parsed.
    private static func textCarrier(of provider: NSItemProvider) -> TextCarrier? {
        let types = provider.registeredTypeIdentifiers.compactMap { identifier in
            UTType(identifier).map { (identifier, $0) }
        }
        if let plain = types.first(where: { $0.1.conforms(to: .plainText) }) {
            return .plainText(identifier: plain.0)
        }
        if let rich = types.first(where: { $0.1.conforms(to: .rtf) }) {
            return .richText(identifier: rich.0)
        }
        return nil
    }

    private func loadURLString(from provider: NSItemProvider) async throws -> String {
        try await provider.loadText(forTypeIdentifier: UTType.url.identifier)
    }

    private func loadTextString(from provider: NSItemProvider) async throws -> String {
        switch Self.textCarrier(of: provider) {
        case let .plainText(identifier)?:
            return try await provider.loadText(forTypeIdentifier: identifier)
        case let .richText(identifier)?:
            return try await provider.loadRichTextString(forTypeIdentifier: identifier)
        case nil:
            throw ShareError.unsupportedContent
        }
    }

    private func loadImagePNG(from provider: NSItemProvider) async throws -> Data {
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

    private func present(_ outcome: ShareConfirmationView.Outcome, onDone: (() -> Void)? = nil) {
        if let previous = hostingController {
            previous.willMove(toParent: nil)
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }
        let host = UIHostingController(rootView: ShareConfirmationView(outcome: outcome, onDone: onDone))
        hostingController = host
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

    /// Writes the error domain and code only, never the shared content or a file name.
    fileprivate nonisolated static func logFailure(_ context: String, _ error: Error) {
        let nsError = error as NSError
        log.error(
            "\(context, privacy: .public) failed. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
    }
}

private extension ShareViewController {
    func enqueue(text: String, in inbox: ShareCaptureInbox) async throws {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                let entry = try inbox.enqueue(text: text, sourceApp: "Share")
                // The clip is already queued; a preview that cannot be written only means the
                // keyboard shows it after the app imports it.
                do {
                    try inbox.publishKeyboardPreview(for: entry)
                } catch {
                    ShareViewController.logFailure("Publishing the keyboard preview", error)
                }
                return entry
            }.value
        } catch ShareCaptureInbox.Error.quotaExceeded {
            throw ShareError.captureQueueFull
        } catch ShareCaptureInbox.Error.textTooLarge {
            throw ShareError.textTooLarge
        } catch ShareCaptureInbox.Error.invalidEntry {
            throw ShareError.emptyText
        } catch {
            Self.logFailure("Queueing shared text", error)
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
            Self.logFailure("Queueing a shared image", error)
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
    /// Reads a text, web URL or UTF-8 data item. A file URL is refused: its contents are not shared.
    @MainActor func loadText(forTypeIdentifier identifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch value {
                case let text as String:
                    continuation.resume(returning: text)
                case let attributed as NSAttributedString:
                    continuation.resume(returning: attributed.string)
                case let data as Data:
                    if let text = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                    }
                case let url as URL:
                    if url.isFileURL {
                        continuation.resume(throwing: ShareViewController.ShareError.fileNotSupported)
                    } else {
                        continuation.resume(returning: url.absoluteString)
                    }
                default:
                    continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                }
            }
        }
    }

    /// Reads RTF bytes and returns their readable text. The bytes are never treated as UTF-8.
    @MainActor func loadRichTextString(forTypeIdentifier identifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                    return
                }
                guard data.count <= SyncBlobKind.text.maximumBytes else {
                    continuation.resume(throwing: ShareViewController.ShareError.textTooLarge)
                    return
                }
                do {
                    let attributed = try NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil
                    )
                    continuation.resume(returning: attributed.string)
                } catch {
                    continuation.resume(throwing: ShareViewController.ShareError.malformedItem)
                }
            }
        }
    }

    @MainActor func loadTemporaryImageFileRepresentation(forTypeIdentifier identifier: String) async throws -> URL? {
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

    @MainActor func loadImageSource(forTypeIdentifier identifier: String) async throws -> ProviderImageSource {
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

    private nonisolated static func copyTemporaryImageFile(at url: URL) throws -> URL {
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
