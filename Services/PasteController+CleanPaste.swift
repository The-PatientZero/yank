import Cocoa

@MainActor
extension PasteController {
    /// Pastes a clip using the cleaning policy, optionally reversing its default for text clips.
    static func paste(_ item: ClipboardItem, store: ClipboardStore,
                      policy: CleanPastePolicy, flipDefault: Bool = false,
                      axPermission: AccessibilityPermission? = nil,
                      previousApp: NSRunningApplication? = nil) {
        guard item.type == .text, policy.cleansByDefault(item) != flipDefault else {
            paste(item, store: store, axPermission: axPermission, previousApp: previousApp)
            return
        }
        let pasteboard = NSPasteboard.general
        let intent = deferredWriteCoordinator.begin(for: pasteboard)
        Task { @MainActor in
            guard let original = await store.fullTextAsync(for: item) else { return }
            let cleaned = await Task.detached(priority: .userInitiated) {
                TerminalTextCleaner.clean(original)
            }.value
            guard cleaned != original else {
                guard deferredWriteCoordinator.claim(intent, for: pasteboard) else { return }
                paste(item, store: store, axPermission: axPermission, previousApp: previousApp)
                return
            }
            axPermission?.refresh()
            if let axPermission, !axPermission.isTrusted {
                guard deferredWriteCoordinator.claim(intent, for: pasteboard),
                      copyTextToClipboard(cleaned, pasteboard: pasteboard) != nil else { return }
                store.moveToTop(item)
                showAccessibilityHUD(axPermission, previousApp: previousApp)
                return
            }
            let result = await pasteTextResult(
                cleaned,
                pasteboard: pasteboard,
                isAccessibilityTrusted: true,
                previousApp: previousApp,
                deferredWriteIntent: intent
            )
            switch result {
            case .dispatched:
                store.moveToTop(item)
            case .pasteboardWriteFailed:
                Log.paste.error("Failed to write cleaned text to the pasteboard")
            case .syntheticEventFailed:
                Log.paste.error("Failed to create cleaned-text paste events")
            case .cancelled, .missingPayload, .accessibilityUnavailable:
                break
            }
        }
    }
}
