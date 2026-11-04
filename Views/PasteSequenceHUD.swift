import AppKit
import Observation
import SwiftUI

enum PasteSequenceHUDProblem: Equatable {
    case capturePaused
    case hotkeyUnavailable
    case accessibilityUnavailable
    case pasteboardWriteFailed
    case syntheticEventFailed
    case capacityReached
}

enum PasteSequenceHUDPhase: Equatable {
    case collecting
    case pasting
    case blocked(PasteSequenceHUDProblem)
    case completed
    case expired
    case cancelled
}

@MainActor
@Observable
final class PasteSequenceHUDState {
    var phase: PasteSequenceHUDPhase = .collecting
    var itemCount = 0
    var nextIndex = 0
    var shortcut = ""
    /// True while the sequence can still be cancelled; the HUD then offers a Cancel button.
    var canCancel = false
    /// Runs when the Cancel button is pressed. Set by the coordinator, which guards against a
    /// late press.
    @ObservationIgnored var onCancel: (() -> Void)?

    var statusText: String {
        switch phase {
        case .collecting:
            return itemCount == 1 ? "1 item copied" : "\(itemCount) items copied"
        case .pasting:
            return "Item \(min(nextIndex + 1, itemCount)) of \(itemCount)"
        case .blocked:
            return "Paste not sent"
        case .completed:
            return "Sequence complete"
        case .expired:
            return "Sequence expired"
        case .cancelled:
            return "Sequence cancelled"
        }
    }

    var detailText: String {
        switch phase {
        case .collecting:
            return itemCount == 0 ? "Copy text to add it" : "\(shortcut) pastes the first item"
        case .pasting:
            return "\(shortcut) pastes the next item"
        case .blocked(let problem):
            switch problem {
            case .capturePaused: return "Resume clipboard capture before starting"
            case .hotkeyUnavailable: return "Choose an available shortcut in Settings"
            case .accessibilityUnavailable: return "Accessibility access is required to paste"
            case .pasteboardWriteFailed: return "The current item is still ready to retry"
            case .syntheticEventFailed: return "The current item is still ready to retry"
            case .capacityReached: return "The 50-item or 16 MiB limit was reached"
            }
        case .completed:
            return "The normal Yank shortcut is restored"
        case .expired:
            return "No queue data was saved"
        case .cancelled:
            return "History and clipboard were not changed"
        }
    }

    var symbolName: String {
        switch phase {
        case .collecting: return "list.number"
        case .pasting: return "arrow.right.to.line"
        case .blocked: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .cancelled: return "xmark.circle"
        }
    }

    var accent: Color {
        switch phase {
        case .blocked: return .yankDanger
        case .completed: return .yankSuccess
        case .collecting, .pasting, .expired, .cancelled: return AppTheme.active.foreground
        }
    }
}

private final class PasteSequencePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the Cancel button alone, so it is the only part of the HUD that takes clicks.
private final class PasteSequenceCancelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click press the button while another app stays frontmost.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PasteSequenceHUDController {
    fileprivate static let panelSize = NSSize(width: 520, height: 76)
    fileprivate static let cancelButtonSize = NSSize(width: 76, height: 28)
    private static let topInset: CGFloat = Space.lg

    let state = PasteSequenceHUDState()

    private let panel: NSPanel
    private let cancelPanel: NSPanel

    init() {
        let panel = PasteSequencePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        let cancelPanel = PasteSequenceCancelPanel(
            contentRect: NSRect(origin: .zero, size: Self.cancelButtonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.cancelPanel = cancelPanel
        cancelPanel.level = .statusBar
        cancelPanel.isFloatingPanel = true
        cancelPanel.hidesOnDeactivate = false
        cancelPanel.becomesKeyOnlyIfNeeded = true
        cancelPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        cancelPanel.backgroundColor = .clear
        cancelPanel.isOpaque = false
        cancelPanel.hasShadow = false
        cancelPanel.animationBehavior = .none

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.setAccessibilityTitle("Paste Sequence")

        panel.contentView = NSHostingView(rootView: PasteSequenceHUDView(state: state))

        cancelPanel.setAccessibilityTitle(PasteSequenceCancelButton.accessibilityLabel)
        let cancelHost = FirstMouseHostingView(rootView: PasteSequenceCancelButton(state: state))
        cancelHost.frame = NSRect(origin: .zero, size: Self.cancelButtonSize)
        cancelPanel.contentView = cancelHost
    }

    func show() {
        moveToActiveDisplay()
        guard !panel.isVisible else {
            syncCancelPanel(alpha: panel.alphaValue)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            syncCancelPanel(alpha: 1)
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        syncCancelPanel(alpha: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = YankPanelTokens.fadeInDuration
            panel.animator().alphaValue = 1
            cancelPanel.animator().alphaValue = 1
        }
    }

    func close() {
        // The button goes at once, so a click during the fade-out finds nothing to press.
        hideCancelPanel()
        guard panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = YankPanelTokens.fadeOutDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            Task { @MainActor in panel?.close() }
        }
    }

    func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// Shows the Cancel button at the HUD's trailing edge while the sequence can be cancelled,
    /// and removes it otherwise. It is a child window, so it moves with the HUD.
    private func syncCancelPanel(alpha: CGFloat) {
        guard state.canCancel else {
            hideCancelPanel()
            return
        }
        let hudFrame = panel.frame
        cancelPanel.setFrameOrigin(NSPoint(
            x: hudFrame.maxX - Space.xl - Self.cancelButtonSize.width,
            y: hudFrame.midY - Self.cancelButtonSize.height / 2
        ))
        cancelPanel.alphaValue = alpha
        if cancelPanel.parent == nil {
            panel.addChildWindow(cancelPanel, ordered: .above)
        }
        cancelPanel.orderFrontRegardless()
    }

    private func hideCancelPanel() {
        if cancelPanel.parent != nil {
            panel.removeChildWindow(cancelPanel)
        }
        cancelPanel.orderOut(nil)
    }

    private func moveToActiveDisplay() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.maxY - Self.panelSize.height - Self.topInset
        ))
    }
}

private struct PasteSequenceHUDView: View {
    @Bindable var state: PasteSequenceHUDState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: state.symbolName)
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(state.accent)
                .frame(width: ControlTarget.compact, height: ControlTarget.compact)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(state.statusText)
                    .font(.system(size: TypeScale.body, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(state.detailText)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.yankTextTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.md)

            if state.canCancel {
                // The Cancel button is its own window; keep the status text clear of it.
                Color.clear
                    .frame(width: PasteSequenceHUDController.cancelButtonSize.width, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.xl)
        .frame(width: PasteSequenceHUDController.panelSize.width,
               height: PasteSequenceHUDController.panelSize.height)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(
                    Color.yankHairline.opacity(colorSchemeContrast == .increased ? 1 : 0.72),
                    lineWidth: colorSchemeContrast == .increased ? Stroke.focusRing : Hairline.width
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Paste Sequence")
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            Color.yankSurface
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

/// The Cancel button, hosted in its own small window so the rest of the HUD stays click-through.
private struct PasteSequenceCancelButton: View {
    static let accessibilityLabel = "Cancel Paste Sequence"

    let state: PasteSequenceHUDState

    var body: some View {
        Button {
            state.onCancel?()
        } label: {
            Text("Cancel")
                .font(.system(size: TypeScale.control, weight: .semibold))
                .foregroundStyle(AppTheme.active.foreground)
                .frame(width: PasteSequenceHUDController.cancelButtonSize.width,
                       height: PasteSequenceHUDController.cancelButtonSize.height)
                .background(Color.yankSubtleFill, in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(Color.yankHairline, lineWidth: Hairline.width)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .help("Stops collecting and pasting. Your clipboard is not changed.")
        .accessibilityLabel(Self.accessibilityLabel)
    }
}
