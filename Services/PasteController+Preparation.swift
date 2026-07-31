import Cocoa

@MainActor
extension PasteController {
    struct ImageTempSource: Sendable {
        let sourceURL: URL
        let fileName: String
    }

    enum PreparedFallback: Sendable {
        case none
        case text(String)
        case imageFile(URL, fallbackPNGData: Data?)
        case imageData(Data)
    }

    struct PreparedSingleContent: Sendable {
        let richArchive: PasteboardArchive?
        let fallback: PreparedFallback
    }

    struct PreparedMultipleContent: Sendable {
        let text: String
        let imageURLs: [URL]

        var hasText: Bool { !text.isEmpty }
        var hasImages: Bool { !imageURLs.isEmpty }
    }

    nonisolated static func getTempDirectory() -> URL? {
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

    nonisolated static func cleanupStaleTempDirectories() {
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

    nonisolated static func cleanupTempFiles(for urls: [URL], after delay: TimeInterval = pasteFileCleanupDelay) {
        guard let plan = PasteTemporaryFileCleanup.planAfterPasteboardWrite(
            fileURLs: urls,
            writeSucceeded: true,
            delay: delay
        ) else { return }
        scheduleCleanup(plan)
    }

    nonisolated static func scheduleTempFileCleanup(
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

    nonisolated static func scheduleCleanup(_ plan: PasteTemporaryFileCleanup.Plan) {
        // Keep file URLs alive long enough for pasteboard consumers to read them before cleanup.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(plan.delay))
            for directory in plan.directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    nonisolated static func removeTempFiles(for urls: [URL]) {
        for directory in PasteTemporaryFileCleanup.directories(containing: urls) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated static func copyImageBlobToTemp(sourceURL: URL, fileName: String) async -> URL? {
        (await copyImageBlobsToTemp([ImageTempSource(sourceURL: sourceURL, fileName: fileName)])).first
    }

    nonisolated static func copyImageBlobsToTemp(_ sources: [ImageTempSource]) async -> [URL] {
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
    static func collectImageTempURLs(_ imageItems: [ClipboardItem], store: ClipboardStore) async -> [URL] {
        let sources = imageItems.enumerated().compactMap { index, imageItem -> ImageTempSource? in
            guard let sourceURL = store.blobURL(for: imageItem) else { return nil }
            let fileName = "image-\(String(format: "%04d", index + 1)).png"
            return ImageTempSource(sourceURL: sourceURL, fileName: fileName)
        }
        return await copyImageBlobsToTemp(sources)
    }

    static func prepareContents(of item: ClipboardItem, store: ClipboardStore) async -> PreparedSingleContent {
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

    static func discardTempFiles(in fallback: PreparedFallback) {
        if case .imageFile(let fileURL, _) = fallback {
            removeTempFiles(for: [fileURL])
        }
    }

    @discardableResult
    static func performPasteboardWrite(
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
    static func writePreparedContents(
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
        let pasteboard = NSPasteboard.general
        let intent = deferredWriteCoordinator.begin(for: pasteboard)
        Task { @MainActor in
            let prepared = await prepareContents(of: item, store: store)
            guard deferredWriteCoordinator.claim(intent, for: pasteboard) else {
                discardTempFiles(in: prepared.fallback)
                return
            }
            guard writePreparedContents(prepared, to: pasteboard) != nil else { return }
            store.moveToTop(item)
        }
    }

    static func copyMultipleToClipboard(_ items: [ClipboardItem], store: ClipboardStore) {
        let pasteboard = NSPasteboard.general
        let intent = deferredWriteCoordinator.begin(for: pasteboard)
        Task { @MainActor in
            if items.count == 1, let item = items.first {
                let prepared = await prepareContents(of: item, store: store)
                guard deferredWriteCoordinator.claim(intent, for: pasteboard) else {
                    discardTempFiles(in: prepared.fallback)
                    return
                }
                guard writePreparedContents(prepared, to: pasteboard) != nil else { return }
                store.moveToTop(items)
                return
            }
            let prepared = await prepareMultipleContents(of: items, store: store)
            guard deferredWriteCoordinator.claim(intent, for: pasteboard) else {
                removeTempFiles(for: prepared.imageURLs)
                return
            }
            guard writePreparedMultipleContents(prepared, to: pasteboard) != nil else { return }
            store.moveToTop(items)
        }
    }

    static func prepareMultipleContents(
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
    static func writePreparedMultipleContents(
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
}
