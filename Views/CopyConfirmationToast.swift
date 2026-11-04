import AppKit
import SwiftUI

/// Posts a VoiceOver announcement from the app.
enum AccessibilityAnnouncement {
    @MainActor
    static func post(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

private final class CopyConfirmationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A "Copied." capsule shown at the bottom centre of a screen after a copy from the Quick
/// Picker, which closes at once and so cannot show it inline. It never takes focus or clicks.
@MainActor
final class CopyConfirmationToastController {
    private static let panelSize = NSSize(width: 160, height: 48)
    private static let bottomInset: CGFloat = Space.xxxl * 2

    private let panel: NSPanel
    private var closeTask: Task<Void, Never>?

    init() {
        let panel = CopyConfirmationPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: CopyConfirmationCapsule())
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
    }

    func show(on screen: NSScreen?) {
        AccessibilityAnnouncement.post("Copied to clipboard")
        position(on: screen ?? NSScreen.main ?? NSScreen.screens.first)

        closeTask?.cancel()
        if !panel.isVisible {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = 1
            } else {
                panel.alphaValue = 0
            }
            panel.orderFrontRegardless()
        }
        fade(to: 1)

        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: CopyConfirmationCapsule.displayDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func position(on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.minY + Self.bottomInset
        ))
    }

    private func fade(to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? YankPanelTokens.fadeInDuration : YankPanelTokens.fadeOutDuration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            Task { @MainActor in completion?() }
        }
    }

    private func dismiss() {
        fade(to: 0) { [weak self] in
            // A newer copy may have re-shown the toast while this one faded out.
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        }
    }
}
