import Cocoa
import UniformTypeIdentifiers

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
    private static func registerSuccessfulWrite(_ didWrite: Bool, to pasteboard: NSPasteboard) -> Bool {
        guard didWrite else { return false }
        NotificationCenter.default.post(
            name: .yankIgnoreNextChange,
            object: pasteboard.changeCount
        )
        return true
    }

    /// Write prepared clip content to a pasteboard. Rich clips (#11) replay every archived
    /// representation verbatim; otherwise the primary text/image is written.
    @discardableResult
    private static func writePreparedContents(
        _ content: PreparedSingleContent,
        to pasteboard: NSPasteboard,
        temporaryFileCleanupDelay: TimeInterval = copyFileCleanupDelay
    ) -> Bool {
        pasteboard.clearContents()

        if let archive = content.richArchive, !archive.isEmpty {
            let pbItem = NSPasteboardItem()
            for rep in archive.representations {
                pbItem.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
            }
            if pasteboard.writeObjects([pbItem]) {
                registerSuccessfulWrite(true, to: pasteboard)
                discardTempFiles(in: content.fallback)
                return true
            }
            pasteboard.clearContents()  // write failed — fall back to the primary type
        }

        switch content.fallback {
        case .none:
            return false
        case .text(let text):
            return registerSuccessfulWrite(pasteboard.setString(text, forType: .string), to: pasteboard)
        case .imageFile(let fileURL, let fallbackPNGData):
            let didWrite = pasteboard.writeObjects([fileURL as NSPasteboardWriting])
            scheduleTempFileCleanup([fileURL], afterPasteboardWrite: didWrite, delay: temporaryFileCleanupDelay)
            if didWrite { return registerSuccessfulWrite(true, to: pasteboard) }
            if let fallbackPNGData {
                return registerSuccessfulWrite(pasteboard.setData(fallbackPNGData, forType: .png), to: pasteboard)
            }
            return false
        case .imageData(let pngData):
            return registerSuccessfulWrite(pasteboard.setData(pngData, forType: .png), to: pasteboard)
        }
    }

    static func copyToClipboard(_ item: ClipboardItem, store: ClipboardStore) {
        Task { @MainActor in
            let prepared = await prepareContents(of: item, store: store)
            writePreparedContents(prepared, to: NSPasteboard.general)
            store.moveToTop(item)
        }
    }

    static func copyMultipleToClipboard(_ items: [ClipboardItem], store: ClipboardStore) {
        Task { @MainActor in
            if items.count == 1, let item = items.first {
                let prepared = await prepareContents(of: item, store: store)
                writePreparedContents(prepared, to: NSPasteboard.general)
                store.moveToTop(items)
                return
            }
            let prepared = await prepareMultipleContents(of: items, store: store)
            writePreparedMultipleContents(prepared, to: NSPasteboard.general)
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
    ) -> Bool {
        var objects: [NSPasteboardWriting] = []
        if content.hasText { objects.append(content.text as NSString) }
        objects.append(contentsOf: content.imageURLs as [NSPasteboardWriting])

        pasteboard.clearContents()
        guard !objects.isEmpty else { return false }
        let didWrite = pasteboard.writeObjects(objects)
        scheduleTempFileCleanup(content.imageURLs, afterPasteboardWrite: didWrite, delay: temporaryFileCleanupDelay)
        return registerSuccessfulWrite(didWrite, to: pasteboard)
    }

    static func paste(_ item: ClipboardItem, store: ClipboardStore,
                      axPermission: AccessibilityPermission? = nil,
                      previousApp: NSRunningApplication? = nil) {
        Task { @MainActor in
            let prepared = await prepareContents(of: item, store: store)
            writePreparedContents(
                prepared,
                to: NSPasteboard.general,
                temporaryFileCleanupDelay: pasteFileCleanupDelay
            )
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        registerSuccessfulWrite(pasteboard.setString(text, forType: .string), to: pasteboard)

        if let axPermission, !axPermission.isTrusted {
            AccessibilityPermission.requestPrompt()
            showAccessibilityHUD()
            return
        }

        // 0.1s focus-settle delay, identical to `paste(_:store:previousApp:)`.
        previousApp?.activate()
        simulatePasteWithCustomDelay(0.1)
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
                writePreparedContents(
                    prepared,
                    to: NSPasteboard.general,
                    temporaryFileCleanupDelay: pasteFileCleanupDelay
                )
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
                writePreparedMultipleContents(
                    prepared,
                    to: NSPasteboard.general,
                    temporaryFileCleanupDelay: pasteFileCleanupDelay
                )
                AccessibilityPermission.requestPrompt()
                showAccessibilityHUD()
                return
            }

            let pasteboard = NSPasteboard.general

            if prepared.hasText {
                pasteboard.clearContents()
                registerSuccessfulWrite(pasteboard.setString(prepared.text, forType: .string), to: pasteboard)

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
        pasteboard.clearContents()
        guard !imageURLs.isEmpty else { return }
        let didWrite = pasteboard.writeObjects(imageURLs as [NSPasteboardWriting])
        guard registerSuccessfulWrite(didWrite, to: pasteboard) else {
            removeTempFiles(for: imageURLs)
            return
        }
        simulatePasteWithCustomDelay(0.05)
        cleanupTempFiles(for: imageURLs)
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Every paste path funnels here, so this is the one place the paste cue belongs.
        Feedback.emit(.paste)
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
