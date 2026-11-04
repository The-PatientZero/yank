import Cocoa
import UniformTypeIdentifiers

@MainActor
extension PasteController {
    /// How long the manual-paste card stays on screen.
    private static let accessibilityCardDuration: Duration = .seconds(6)

    /// Shown after a pick copied a clip but Accessibility access is missing, so Yank cannot paste:
    /// tells the user to press ⌘V and offers the one shared grant flow. The card never takes focus;
    /// `previousApp` is brought back to the front (only if Yank is still active, so a late pick
    /// does not pull the user back to a stale app) so the user's ⌘V lands there.
    static func showAccessibilityHUD(_ permission: AccessibilityPermission,
                                     previousApp: NSRunningApplication? = nil) {
        if NSApp.isActive {
            previousApp?.activate()
        }

        // Only one card exists at a time: a newer pick replaces the earlier card.
        PasteControllerHUDOpener.shared.pendingPanel?.close()

        let (panel, content) = YankPanelFactory.makePanel(
            size: YankPanelTokens.compactToastPanelSize,
            title: accessibilityCardTitle,
            anchorApp: previousApp
        )
        panel.setAccessibilityTitle(accessibilityCardAnnouncement)
        content.setAccessibilityLabel(accessibilityCardAnnouncement)

        PasteControllerHUDOpener.shared.permission = permission
        PasteControllerHUDOpener.shared.pendingPanel = panel

        let enableButton = YankPanelFactory.makeButton(
            title: "Enable auto-paste",
            target: PasteControllerHUDOpener.shared,
            action: #selector(PasteControllerHUDOpener.grantAccess(_:)),
            accessibilityLabel: "Enable auto-paste",
            accessibilityHelp: "Opens Accessibility settings so Yank can paste for you."
        )

        YankPanelFactory.populateCard(
            content: content,
            configuration: YankPanelCardConfiguration(
                symbolName: "doc.on.clipboard",
                accentColor: YankPanelTokens.infoGlyph,
                title: accessibilityCardTitle,
                message: "Press ⌘V to paste.",
                detail: "Turn on Accessibility access to paste automatically.",
                actions: [enableButton]
            )
        )

        panel.alphaValue = 0
        YankPanelFactory.show(panel)
        YankPanelFactory.fadeIn(panel)
        // A non-key panel is not announced by itself.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: accessibilityCardAnnouncement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
        Task { @MainActor in
            try? await Task.sleep(for: accessibilityCardDuration)
            guard PasteControllerHUDOpener.shared.pendingPanel === panel else { return }
            YankPanelFactory.fadeOut(panel) {
                if PasteControllerHUDOpener.shared.pendingPanel === panel {
                    PasteControllerHUDOpener.shared.pendingPanel = nil
                    PasteControllerHUDOpener.shared.permission = nil
                }
                panel.close()
            }
        }
    }

    private static let accessibilityCardTitle = "Copied"
    private static let accessibilityCardAnnouncement = "Copied. Press Command V to paste."

    /// Wait for target focus, then dispatch only while the pasteboard still contains the exact
    /// generation Yank wrote. A newer external copy must never become the payload of Yank's
    /// delayed synthetic Command + V.
    static func dispatchPasteIfCurrent(
        receipt: PasteboardWriteReceipt,
        pasteboard: NSPasteboard = .general,
        delay: Duration,
        sleeper: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task<Never, Never>.sleep(for: $0)
        },
        eventDispatcher: @escaping @MainActor () -> Bool = { simulatePaste() }
    ) async -> Bool {
        do {
            try await sleeper(delay)
        } catch {
            return false
        }
        guard !Task.isCancelled, receipt.isCurrent(on: pasteboard) else { return false }
        return eventDispatcher()
    }

    /// Simulate Command + V after a deliberate delay. The delay is load-bearing — it gives the
    /// OS time to finish activating the target app and process any preceding synthetic ⌘V
    /// first.
    static func simulatePasteWithCustomDelay(
        _ delay: TimeInterval,
        receipt: PasteboardWriteReceipt,
        pasteboard: NSPasteboard
    ) {
        Task { @MainActor in
            _ = await dispatchPasteIfCurrent(
                receipt: receipt,
                pasteboard: pasteboard,
                delay: .seconds(delay)
            )
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
    var permission: AccessibilityPermission?
    var pendingPanel: NSPanel?

    @objc func grantAccess(_ sender: Any?) {
        permission?.grantAccess()
        pendingPanel?.close()
        pendingPanel = nil
        permission = nil
    }
}
