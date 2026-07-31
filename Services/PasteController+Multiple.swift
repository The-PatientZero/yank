import Cocoa

@MainActor
extension PasteController {
    private struct MultiplePasteContext {
        let items: [ClipboardItem]
        let store: ClipboardStore
        let pasteboard: NSPasteboard
        let intent: DeferredPasteboardWriteCoordinator.Intent
        let previousApp: NSRunningApplication?
    }

    /// Paste text clips as one newline-joined string, followed by image file URLs.
    static func pasteMultiple(
        _ items: [ClipboardItem],
        store: ClipboardStore,
        axPermission: AccessibilityPermission? = nil,
        previousApp: NSRunningApplication? = nil
    ) {
        guard !items.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let intent = deferredWriteCoordinator.begin(for: pasteboard)
        let context = MultiplePasteContext(
            items: items,
            store: store,
            pasteboard: pasteboard,
            intent: intent,
            previousApp: previousApp
        )
        Task { @MainActor in
            if items.count == 1, let item = items.first {
                await pasteSingleSelection(
                    item,
                    context: context,
                    axPermission: axPermission
                )
                return
            }

            let content = await prepareMultipleContents(of: items, store: store)
            if axPermission?.isTrusted == false {
                copyForManualPaste(content, context: context)
                return
            }
            dispatchMultiple(content, context: context)
        }
    }

    private static func pasteSingleSelection(
        _ item: ClipboardItem,
        context: MultiplePasteContext,
        axPermission: AccessibilityPermission?
    ) async {
        let prepared = await prepareContents(of: item, store: context.store)
        guard deferredWriteCoordinator.claim(context.intent, for: context.pasteboard) else {
            discardTempFiles(in: prepared.fallback)
            return
        }
        guard let receipt = writePreparedContents(
            prepared,
            to: context.pasteboard,
            temporaryFileCleanupDelay: pasteFileCleanupDelay
        ) else { return }
        context.store.moveToTop(context.items)

        if axPermission?.isTrusted == false {
            AccessibilityPermission.requestPrompt()
            showAccessibilityHUD()
            return
        }

        context.previousApp?.activate()
        simulatePasteWithCustomDelay(0.1, receipt: receipt, pasteboard: context.pasteboard)
    }

    private static func copyForManualPaste(
        _ content: PreparedMultipleContent,
        context: MultiplePasteContext
    ) {
        guard deferredWriteCoordinator.claim(context.intent, for: context.pasteboard) else {
            removeTempFiles(for: content.imageURLs)
            return
        }
        guard writePreparedMultipleContents(
            content,
            to: context.pasteboard,
            temporaryFileCleanupDelay: pasteFileCleanupDelay
        ) != nil else { return }

        context.store.moveToTop(context.items)
        AccessibilityPermission.requestPrompt()
        showAccessibilityHUD()
    }

    private static func dispatchMultiple(
        _ content: PreparedMultipleContent,
        context: MultiplePasteContext
    ) {
        if content.hasText {
            pasteTextThenImages(content, context: context)
        } else if content.hasImages {
            pasteImagesOnly(content.imageURLs, context: context)
        } else {
            _ = deferredWriteCoordinator.claim(context.intent, for: context.pasteboard)
        }
    }

    private static func pasteTextThenImages(
        _ content: PreparedMultipleContent,
        context: MultiplePasteContext
    ) {
        guard deferredWriteCoordinator.claim(context.intent, for: context.pasteboard),
              let receipt = copyTextToClipboard(
                  content.text,
                  pasteboard: context.pasteboard
              ) else {
            removeTempFiles(for: content.imageURLs)
            return
        }
        context.store.moveToTop(context.items)
        context.previousApp?.activate()
        simulatePasteWithCustomDelay(0.1, receipt: receipt, pasteboard: context.pasteboard)

        guard content.hasImages else { return }
        guard context.pasteboard.changeCount == receipt.generation else {
            removeTempFiles(for: content.imageURLs)
            return
        }

        let imageIntent = deferredWriteCoordinator.begin(for: context.pasteboard)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard deferredWriteCoordinator.claim(
                imageIntent,
                for: context.pasteboard
            ) else {
                removeTempFiles(for: content.imageURLs)
                return
            }
            pasteImagesTogether(content.imageURLs, pasteboard: context.pasteboard)
        }
    }

    private static func pasteImagesOnly(
        _ imageURLs: [URL],
        context: MultiplePasteContext
    ) {
        context.previousApp?.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.1))
            guard deferredWriteCoordinator.claim(
                context.intent,
                for: context.pasteboard
            ) else {
                removeTempFiles(for: imageURLs)
                return
            }
            guard pasteImagesTogether(
                imageURLs,
                pasteboard: context.pasteboard
            ) != nil else { return }
            context.store.moveToTop(context.items)
        }
    }

    @discardableResult
    private static func pasteImagesTogether(
        _ imageURLs: [URL],
        pasteboard: NSPasteboard
    ) -> PasteboardWriteReceipt? {
        guard !imageURLs.isEmpty else { return nil }
        guard let receipt = performPasteboardWrite(
            to: pasteboard,
            { pasteboard.writeObjects(imageURLs as [NSPasteboardWriting]) }
        ) else {
            removeTempFiles(for: imageURLs)
            return nil
        }
        simulatePasteWithCustomDelay(0.05, receipt: receipt, pasteboard: pasteboard)
        cleanupTempFiles(for: imageURLs)
        return receipt
    }
}
