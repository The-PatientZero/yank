import Cocoa
import UniformTypeIdentifiers

@MainActor
extension PasteController {
    static func showAccessibilityHUD() {
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
