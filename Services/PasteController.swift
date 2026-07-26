import Cocoa
import UniformTypeIdentifiers

enum PasteDispatchResult: Equatable {
    case dispatched(pasteboardGeneration: Int)
    case cancelled
    case missingPayload
    case pasteboardWriteFailed
    case accessibilityUnavailable
    case syntheticEventFailed
}

struct PasteboardWriteReceipt: Equatable, Sendable {
    let pasteboardName: String
    let generation: Int
}

/// Handles pasting content into the frontmost application.
///
/// Caseless `enum` used purely as a namespace — it has only static members and must never
/// be instantiated.
@MainActor
enum PasteController {
    nonisolated private static let staleTempDirectoryAge: TimeInterval = 24 * 60 * 60
    nonisolated private static let pasteFileCleanupDelay: TimeInterval = 60
    // Copy has no paste moment; keep file URLs briefly without waiting for stale cleanup.
    nonisolated private static let copyFileCleanupDelay: TimeInterval = 10 * 60

    private struct ImageTempSource: Sendable {
        let sourceURL: URL
        let fileName: String
    }

    private enum PreparedFallback: Sendable {
        case none
        case text(String)
        case imageFile(URL, fallbackPNGData: Data?)
        case imageData(Data)
    }

    private struct PreparedSingleContent: Sendable {
        let richArchive: PasteboardArchive?
        let fallback: PreparedFallback
    }

    private struct PreparedMultipleContent: Sendable {
        let text: String
        let imageURLs: [URL]

        var hasText: Bool { !text.isEmpty }
        var hasImages: Bool { !imageURLs.isEmpty }
    }

    private nonisolated static func getTempDirectory() -> URL? {
        cleanupStaleTempDirectories()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("YankPaste_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return tempDir
        } catch {
            Log.paste.error("Failed to create paste temp directory: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func cleanupStaleTempDirectories() {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-staleTempDirectoryAge)
        for url in contents where url.lastPathComponent.hasPrefix("YankPaste_") {
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if createdAt < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private nonisolated static func cleanupTempFiles(for urls: [URL], after delay: TimeInterval = pasteFileCleanupDelay) {
        guard let plan = PasteTemporaryFileCleanup.planAfterPasteboardWrite(
            fileURLs: urls,
            writeSucceeded: true,
            delay: delay
        ) else { return }
        scheduleCleanup(plan)
    }

    private nonisolated static func scheduleTempFileCleanup(
        _ urls: [URL],
        afterPasteboardWrite didWrite: Bool,
        delay: TimeInterval
    ) {
        guard let plan = PasteTemporaryFileCleanup.planAfterPasteboardWrite(
            fileURLs: urls,
            writeSucceeded: didWrite,
            delay: delay
        ) else {
            if !didWrite {
                removeTempFiles(for: urls)
            }
            return
        }
        scheduleCleanup(plan)
    }

    private nonisolated static func scheduleCleanup(_ plan: PasteTemporaryFileCleanup.Plan) {
        // Keep file URLs alive long enough for pasteboard consumers to read them before cleanup.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(plan.delay))
            for directory in plan.directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private nonisolated static func removeTempFiles(for urls: [URL]) {
        for directory in PasteTemporaryFileCleanup.directories(containing: urls) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated static func copyImageBlobToTemp(sourceURL: URL, fileName: String) async -> URL? {
        (await copyImageBlobsToTemp([ImageTempSource(sourceURL: sourceURL, fileName: fileName)])).first
    }

    private nonisolated static func copyImageBlobsToTemp(_ sources: [ImageTempSource]) async -> [URL] {
        guard !sources.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            guard let tempDir = getTempDirectory() else { return [] }
            var imageURLs: [URL] = []
            for source in sources {
                let fileURL = tempDir.appendingPathComponent(source.fileName)
                do {
                    try FileManager.default.copyItem(at: source.sourceURL, to: fileURL)
                    imageURLs.append(fileURL)
                } catch {
                    Log.paste.error("Failed to copy paste temp image: \(error.localizedDescription)")
                }
            }
            if imageURLs.isEmpty {
                try? FileManager.default.removeItem(at: tempDir)
            }
            return imageURLs
        }.value
    }

    /// Copy stored image blobs to one temp directory and return the written file URLs
    /// (skipping any that fail). Shared by the text-then-images and images-only paste paths.
    private static func collectImageTempURLs(_ imageItems: [ClipboardItem], store: ClipboardStore) async -> [URL] {
        let sources = imageItems.enumerated().compactMap { index, imageItem -> ImageTempSource? in
            guard let sourceURL = store.blobURL(for: imageItem) else { return nil }
            let fileName = "image-\(String(format: "%04d", index + 1)).png"
            return ImageTempSource(sourceURL: sourceURL, fileName: fileName)
        }
        return await copyImageBlobsToTemp(sources)
    }

    private static func prepareContents(of item: ClipboardItem, store: ClipboardStore) async -> PreparedSingleContent {
        let richArchive = await store.richArchiveAsync(for: item)
        let fallback: PreparedFallback
        switch item.type {
        case .text:
            if let text = await store.fullTextAsync(for: item) {
                fallback = .text(text)
            } else {
                fallback = .none
            }
        case .image:
            if let sourceURL = store.blobURL(for: item),
               let fileURL = await copyImageBlobToTemp(sourceURL: sourceURL, fileName: "image-0001.png") {
                fallback = .imageFile(fileURL, fallbackPNGData: nil)
            } else if let pngData = await store.imagePNGDataAsync(for: item) {
                fallback = .imageData(pngData)
            } else {
                fallback = .none
            }
        }
        return PreparedSingleContent(richArchive: richArchive, fallback: fallback)
    }

    private static func discardTempFiles(in fallback: PreparedFallback) {
        if case .imageFile(let fileURL, _) = fallback {
            removeTempFiles(for: [fileURL])
        }
    }

    @discardableResult
    private static func performPasteboardWrite(
        to pasteboard: NSPasteboard,
        _ write: () -> Bool
    ) -> PasteboardWriteReceipt? {
        pasteboard.clearContents()
        guard write() else { return nil }
        let receipt = PasteboardWriteReceipt(
            pasteboardName: pasteboard.name.rawValue,
            generation: pasteboard.changeCount
        )
        NotificationCenter.default.post(
            name: .yankIgnoreNextChange,
            object: receipt
        )
        return receipt
    }

    @discardableResult
    static func copyTextToClipboard(
        _ text: String,
        pasteboard: NSPasteboard = .general
    ) -> PasteboardWriteReceipt? {
        guard !text.isEmpty else { return nil }
        return performPasteboardWrite(to: pasteboard) {
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Write prepared clip content to a pasteboard. Rich clips (#11) replay every archived
    /// representation verbatim; otherwise the primary text/image is written.
    @discardableResult
    private static func writePreparedContents(
        _ content: PreparedSingleContent,
        to pasteboard: NSPasteboard,
        temporaryFileCleanupDelay: TimeInterval = copyFileCleanupDelay
    ) -> PasteboardWriteReceipt? {
        if let archive = content.richArchive, !archive.isEmpty {
            let pbItem = NSPasteboardItem()
            for rep in archive.representations {
                pbItem.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
            }
            if let receipt = performPasteboardWrite(
                to: pasteboard,
                { pasteboard.writeObjects([pbItem]) }
            ) {
                discardTempFiles(in: content.fallback)
                return receipt
            }
        }

        switch content.fallback {
        case .none:
            return nil
        case .text(let text):
            return copyTextToClipboard(text, pasteboard: pasteboard)
        case .imageFile(let fileURL, let fallbackPNGData):
            if let receipt = performPasteboardWrite(
                to: pasteboard,
                { pasteboard.writeObjects([fileURL as NSPasteboardWriting]) }
            ) {
                scheduleTempFileCleanup(
                    [fileURL],
                    afterPasteboardWrite: true,
                    delay: temporaryFileCleanupDelay
                )
                return receipt
            }
            removeTempFiles(for: [fileURL])
            if let fallbackPNGData {
                return performPasteboardWrite(to: pasteboard) {
                    pasteboard.setData(fallbackPNGData, forType: .png)
                }
            }
            return nil
        case .imageData(let pngData):
            return performPasteboardWrite(to: pasteboard) {
                pasteboard.setData(pngData, forType: .png)
            }
        }
    }

    static func copyToClipboard(_ item: ClipboardItem, store: ClipboardStore) {
        Task { @MainActor in
            let prepared = await prepareContents(of: item, store: store)
            guard writePreparedContents(prepared, to: NSPasteboard.general) != nil else { return }
            store.moveToTop(item)
        }
    }

    static func copyMultipleToClipboard(_ items: [ClipboardItem], store: ClipboardStore) {
        Task { @MainActor in
            if items.count == 1, let item = items.first {
                let prepared = await prepareContents(of: item, store: store)
                guard writePreparedContents(prepared, to: NSPasteboard.general) != nil else { return }
                store.moveToTop(items)
                return
            }
            let prepared = await prepareMultipleContents(of: items, store: store)
            guard writePreparedMultipleContents(prepared, to: NSPasteboard.general) != nil else { return }
            store.moveToTop(items)
        }
    }

    private static func prepareMultipleContents(
        of items: [ClipboardItem],
        store: ClipboardStore
    ) async -> PreparedMultipleContent {
        guard !items.isEmpty else { return PreparedMultipleContent(text: "", imageURLs: []) }
        if items.count == 1, let item = items.first {
            let prepared = await prepareContents(of: item, store: store)
            let text: String
            let imageURLs: [URL]
            switch prepared.fallback {
            case .none, .imageData:
                text = ""
                imageURLs = []
            case .text(let value):
                text = value
                imageURLs = []
            case .imageFile(let fileURL, _):
                text = ""
                imageURLs = [fileURL]
            }
            return PreparedMultipleContent(text: text, imageURLs: imageURLs)
        }

        var textParts: [String] = []
        for item in items where item.type == .text {
            if let text = await store.fullTextAsync(for: item) {
                textParts.append(text)
            }
        }
        let imageURLs = await collectImageTempURLs(items.filter { $0.type == .image }, store: store)
        return PreparedMultipleContent(text: textParts.joined(separator: "\n"), imageURLs: imageURLs)
    }

    @discardableResult
    private static func writePreparedMultipleContents(
        _ content: PreparedMultipleContent,
        to pasteboard: NSPasteboard,
        temporaryFileCleanupDelay: TimeInterval = copyFileCleanupDelay
    ) -> PasteboardWriteReceipt? {
        var objects: [NSPasteboardWriting] = []
        if content.hasText { objects.append(content.text as NSString) }
        objects.append(contentsOf: content.imageURLs as [NSPasteboardWriting])

        guard !objects.isEmpty else { return nil }
        let receipt = performPasteboardWrite(to: pasteboard) {
            pasteboard.writeObjects(objects)
        }
        scheduleTempFileCleanup(
            content.imageURLs,
            afterPasteboardWrite: receipt != nil,
            delay: temporaryFileCleanupDelay
        )
        return receipt
    }

    static func paste(_ item: ClipboardItem, store: ClipboardStore,
                      axPermission: AccessibilityPermission? = nil,
                      previousApp: NSRunningApplication? = nil) {
        Task { @MainActor in
            let prepared = await prepareContents(of: item, store: store)
            guard writePreparedContents(
                prepared,
                to: NSPasteboard.general,
                temporaryFileCleanupDelay: pasteFileCleanupDelay
            ) != nil else { return }
            store.moveToTop(item)

            if let axPermission, !axPermission.isTrusted {
                AccessibilityPermission.requestPrompt()
                showAccessibilityHUD()
                return
            }

            // Reactivate previous app, then simulate paste once it has focus. The 0.1s delay is
            // deliberate — the OS needs time to bring `previousApp` to the foreground before the
            // synthetic ⌘V lands.
            previousApp?.activate()
            simulatePasteWithCustomDelay(0.1)
        }
    }

    /// Paste a plain-text string (e.g. an image's OCR text) into the frontmost app.
    static func pasteText(_ text: String, axPermission: AccessibilityPermission? = nil,
                          previousApp: NSRunningApplication? = nil) {
        // Preserve the existing copy-first fallback for ordinary Yank pastes: without
        // Accessibility permission the text still lands on the clipboard for manual ⌘V.
        // Paste Sequence preflights permission and calls the result-bearing API directly.
        if let axPermission, !axPermission.isTrusted {
            guard copyTextToClipboard(text) != nil else { return }
            AccessibilityPermission.requestPrompt()
            showAccessibilityHUD()
            return
        }

        Task { @MainActor in
            let result = await pasteTextResult(
                text,
                isAccessibilityTrusted: true,
                previousApp: previousApp
            )
            switch result {
            case .pasteboardWriteFailed:
                Log.paste.error("Failed to write plain text to the pasteboard")
            case .syntheticEventFailed:
                Log.paste.error("Failed to create synthetic paste events")
            case .cancelled, .missingPayload, .accessibilityUnavailable, .dispatched:
                break
            }
        }
    }

    /// Result-bearing plain-text dispatch used by Paste Sequence and the existing text path.
    /// Target-app acceptance is not observable; `.dispatched` means the pasteboard write and
    /// synthetic event creation/post both completed.
    static func pasteTextResult(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        isAccessibilityTrusted: Bool,
        previousApp: NSRunningApplication? = nil,
        targetActivator: @escaping @MainActor (NSRunningApplication?) -> Void = { application in
            _ = application?.activate()
        },
        focusSettleDelay: Duration = .milliseconds(100),
        focusSettler: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task<Never, Never>.sleep(for: $0)
        },
        pasteboardWriter: @escaping @MainActor (String, NSPasteboard) -> Bool = {
            $1.setString($0, forType: .string)
        },
        eventDispatcher: @escaping @MainActor () -> Bool = { simulatePaste() }
    ) async -> PasteDispatchResult {
        guard !text.isEmpty else { return .missingPayload }
        guard isAccessibilityTrusted else { return .accessibilityUnavailable }

        targetActivator(previousApp)
        do {
            try await focusSettler(focusSettleDelay)
        } catch {
            return .cancelled
        }
        guard !Task.isCancelled else { return .cancelled }

        guard let receipt = performPasteboardWrite(
            to: pasteboard,
            { pasteboardWriter(text, pasteboard) }
        ) else {
            return .pasteboardWriteFailed
        }

        guard eventDispatcher() else { return .syntheticEventFailed }
        return .dispatched(pasteboardGeneration: receipt.generation)
    }

    /// Smart Paste: transform a text clip's content on-device, then paste the result. The
    /// transform is throwaway (never stored); on failure or when the model is unavailable it
    /// falls back to the original text. The transform is awaited *before* the pasteboard write,
    /// so the 0.1s focus-settle in `pasteText` stays correct regardless of inference latency.
    static func pasteTransformed(_ item: ClipboardItem, as transform: TextTransform,
                                 store: ClipboardStore,
                                 transformer: TextTransformer = FoundationModelTransformer(),
                                 axPermission: AccessibilityPermission? = nil,
                                 previousApp: NSRunningApplication? = nil) {
        Task { @MainActor in
            guard let original = await store.fullTextAsync(for: item), !original.isEmpty else { return }
            let result = await transformer.transform(original, as: transform) ?? original
            store.moveToTop(item)
            pasteText(result, axPermission: axPermission, previousApp: previousApp)
        }
    }

    /// Pastes text clips as one newline-joined string, then pastes image clips as file URLs when present.
    static func pasteMultiple(_ items: [ClipboardItem], store: ClipboardStore,
                              axPermission: AccessibilityPermission? = nil,
                              previousApp: NSRunningApplication? = nil) {
        guard !items.isEmpty else { return }

        Task { @MainActor in
            if items.count == 1, let item = items.first {
                let prepared = await prepareContents(of: item, store: store)
                guard writePreparedContents(
                    prepared,
                    to: NSPasteboard.general,
                    temporaryFileCleanupDelay: pasteFileCleanupDelay
                ) != nil else { return }
                store.moveToTop(items)

                if let axPermission, !axPermission.isTrusted {
                    AccessibilityPermission.requestPrompt()
                    showAccessibilityHUD()
                    return
                }

                previousApp?.activate()
                simulatePasteWithCustomDelay(0.1)
                return
            }

            let prepared = await prepareMultipleContents(of: items, store: store)
            store.moveToTop(items)

            if let axPermission, !axPermission.isTrusted {
                guard writePreparedMultipleContents(
                    prepared,
                    to: NSPasteboard.general,
                    temporaryFileCleanupDelay: pasteFileCleanupDelay
                ) != nil else { return }
                AccessibilityPermission.requestPrompt()
                showAccessibilityHUD()
                return
            }

            let pasteboard = NSPasteboard.general

            if prepared.hasText {
                guard copyTextToClipboard(prepared.text, pasteboard: pasteboard) != nil else {
                    removeTempFiles(for: prepared.imageURLs)
                    return
                }

                if !prepared.hasImages {
                    previousApp?.activate()
                    simulatePasteWithCustomDelay(0.1)
                    return
                }

                previousApp?.activate()
                simulatePasteWithCustomDelay(0.1)

                // Then paste all images together. The 0.5s gap is deliberate — it lets the text
                // ⌘V finish landing and the pasteboard settle before we overwrite it with images.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.5))
                    pasteImagesTogether(prepared.imageURLs, pasteboard: pasteboard)
                }
            } else if prepared.hasImages {
                // Images only - paste all together at once (like Finder multi-select). The 0.1s
                // delay is the same focus-settle grace period used by the single-item paste paths.
                previousApp?.activate()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.1))
                    pasteImagesTogether(prepared.imageURLs, pasteboard: pasteboard)
                }
            }
        }
    }

    /// Write the selected images to the pasteboard as file URLs, paste them in one go, then
    /// clean up the temp files. Shared by the images-only and text-then-images paths.
    private static func pasteImagesTogether(
        _ imageURLs: [URL],
        pasteboard: NSPasteboard
    ) {
        guard !imageURLs.isEmpty else { return }
        guard performPasteboardWrite(
            to: pasteboard,
            { pasteboard.writeObjects(imageURLs as [NSPasteboardWriting]) }
        ) != nil else {
            removeTempFiles(for: imageURLs)
            return
        }
        simulatePasteWithCustomDelay(0.05)
        cleanupTempFiles(for: imageURLs)
    }

    @discardableResult
    private static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // Every paste path funnels here, so this is the one place the paste cue belongs.
        Feedback.emit(.paste)
        return true
    }

    private static func showAccessibilityHUD() {
        let (panel, content) = YankPanelFactory.makePanel(
            size: YankPanelTokens.compactToastPanelSize,
            title: "Accessibility access needed"
        )
        panel.setAccessibilityTitle("Accessibility access needed")
        content.setAccessibilityLabel("Accessibility access needed")

        PasteControllerHUDOpener.shared.pendingURL = AccessibilityPermission.settingsURL
        PasteControllerHUDOpener.shared.pendingPanel = panel

        let settingsButton = YankPanelFactory.makeButton(
            title: "Open System Settings",
            style: .primary,
            target: PasteControllerHUDOpener.shared,
            action: #selector(PasteControllerHUDOpener.openSettings(_:)),
            accessibilityLabel: "Open System Settings",
            accessibilityHelp: "Opens Privacy and Security settings for Accessibility access."
        )
        panel.defaultButtonCell = settingsButton.cell as? NSButtonCell

        YankPanelFactory.populateCard(
            content: content,
            configuration: YankPanelCardConfiguration(
                symbolName: "lock.fill",
                accentColor: YankPanelTokens.warningGlyph,
                eyebrow: "Permission needed",
                title: "Accessibility access needed",
                message: "Clip copied. Grant access to auto-paste.",
                detail: nil,
                textAlignment: .leading,
                actionAlignment: .trailing,
                verticalPlacement: .top,
                actions: [settingsButton]
            )
        )

        panel.alphaValue = 0
        YankPanelFactory.show(panel)
        YankPanelFactory.fadeIn(panel)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard PasteControllerHUDOpener.shared.pendingPanel === panel else { return }
            YankPanelFactory.fadeOut(panel) {
                if PasteControllerHUDOpener.shared.pendingPanel === panel {
                    PasteControllerHUDOpener.shared.pendingPanel = nil
                    PasteControllerHUDOpener.shared.pendingURL = nil
                }
                panel.close()
            }
        }
    }

    /// Simulate Command + V keystroke after a deliberate delay.
    ///
    /// The `delay` is load-bearing: it gives the OS time to finish activating the target app
    /// and to process any preceding synthetic ⌘V before this keystroke is posted.
    private static func simulatePasteWithCustomDelay(_ delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            simulatePaste()
        }
    }

    static func saveImageToDisk(_ image: NSImage) {
        // Defer presentation to a fresh main-actor turn so the modal panel does not run
        // synchronously inside the caller (e.g. a menu/button action). No timing delay.
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())

            panel.nameFieldStringValue = "Image-\(timestamp)"
            panel.canCreateDirectories = true

            if panel.runModal() == .OK, let url = panel.url {
                guard let pngData = image.pngData() else {
                    Log.paste.error("Failed to create PNG data from image")
                    return
                }

                Task.detached(priority: .utility) {
                    do {
                        try pngData.write(to: url, options: .atomic)
                    } catch {
                        Log.paste.error("Failed to save image to disk: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

@MainActor
final class PasteControllerHUDOpener: NSObject {
    static let shared = PasteControllerHUDOpener()
    var pendingURL: URL?
    var pendingPanel: NSPanel?

    @objc func openSettings(_ sender: Any?) {
        if let url = pendingURL {
            NSWorkspace.shared.open(url)
        }
        pendingPanel?.close()
        pendingPanel = nil
        pendingURL = nil
    }
}
