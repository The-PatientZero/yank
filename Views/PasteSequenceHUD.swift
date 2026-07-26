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

@MainActor
final class PasteSequenceHUDController {
    fileprivate static let panelSize = NSSize(width: 520, height: 76)
    private static let topInset: CGFloat = Space.lg

    let state = PasteSequenceHUDState()

    private let panel: NSPanel

    init() {
        let panel = PasteSequencePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

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
    }

    func show() {
        moveToActiveDisplay()
        guard !panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = YankPanelTokens.fadeInDuration
            panel.animator().alphaValue = 1
        }
    }

    func close() {
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
