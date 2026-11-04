import Cocoa
import SwiftUI

/// The menu-bar status item. It owns the brand glyph, visibility, tooltip, right-click
/// command panel, and left-click routing to clipboard history. The app-global footer
/// (update controls, restart, quit) is supplied by the composition root.
@MainActor
final class HubController {
    private var statusItem: NSStatusItem
    private var menuPopover: NSPopover?
    private var menuPasteTargetApplication: NSRunningApplication?
    private let footer: HubAppFooter
    private let settings: SettingsManager

    private var primaryPanelProvider: (@MainActor () -> HubPrimaryPanel)?

    /// A sync problem has to last this long before the icon shows a dot, so a push that fails
    /// once and recovers on its first retry (5 s) never flashes it.
    private static let syncAttentionDelay: Duration = .seconds(30)
    private var syncAttentionShown = false
    private var syncAttentionTask: Task<Void, Never>?
    private var tooltipParts: (headline: String, syncProblem: String?, hint: String) = ("", nil, "")
    private var capturePaused: Bool
    private var renderedGlyphState: IconState?

    /// Everything the menu-bar glyph shows. The image is rebuilt only when this changes.
    private struct IconState: Equatable {
        let paused: Bool
        let updateText: String?
        let syncProblem: Bool

        var accessibilityDescription: String {
            let states = [paused ? "capture paused" : nil, updateText, syncProblem ? "sync problem" : nil]
            return (["Yank"] + states.compactMap { $0 }).joined(separator: ", ")
        }
    }

    init(footer: HubAppFooter, settings: SettingsManager = .shared) {
        self.footer = footer
        self.settings = settings
        capturePaused = settings.capturePaused
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setupButton()
        statusItem.isVisible = settings.showMenuBarIcon
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarVisibilityChanged),
                                               name: .yankMenuBarVisibilityChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didCapture),
                                               name: .yankDidCapture, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateStateChanged),
                                               name: .yankUpdateStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncStatusChanged),
                                               name: .yankSyncStatusChanged, object: nil)
        refreshGlyph()
    }

    func setPrimaryPanelProvider(_ provider: (@MainActor () -> HubPrimaryPanel)?) {
        primaryPanelProvider = provider
    }

    /// Visual only: shows or clears the pause state on the icon. It never changes the saved pause.
    func showCapturePaused(_ paused: Bool) {
        capturePaused = paused
        refreshGlyph()
    }

    /// The tooltip is the shortcut line, then the pause and update lines the hub owns, then the
    /// sync problem while the icon shows its dot, then the hint, so they never overwrite each other.
    func setTooltip(headline: String, syncProblem: String?, hint: String) {
        tooltipParts = (headline, syncProblem, hint)
        applyTooltip()
    }

    private func applyTooltip() {
        let lines = [
            tooltipParts.headline,
            capturePaused ? Self.pausedTooltipLine : nil,
            footer.updateAttention(),
            syncAttentionShown ? tooltipParts.syncProblem : nil,
            tooltipParts.hint
        ]
        statusItem.button?.toolTip = lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func statusItemAnchorFrame() -> NSRect? {
        guard statusItem.isVisible,
              let button = statusItem.button,
              let window = button.window,
              !button.bounds.isEmpty else { return nil }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrameInWindow)
    }

    // MARK: - Status item

    @objc private func menuBarVisibilityChanged() {
        statusItem.isVisible = settings.showMenuBarIcon
    }

    @objc private func didCapture() {
        pulseGlyph()
    }

    @objc private func updateStateChanged() {
        refreshMenu()
        refreshGlyph()
    }

    @objc private func syncStatusChanged() {
        refreshMenu()
        evaluateSyncAttention()
    }

    /// Decides whether the icon shows the attention dot. It never changes while sync is running,
    /// so "Sync now" does not make a visible dot flicker off and back on.
    private func evaluateSyncAttention() {
        let summary = primaryPanelProvider?().sync ?? .off
        if summary.isSyncing { return }
        guard summary.hasProblem else {
            cancelSyncAttentionTimer()
            setSyncAttention(shown: false)
            return
        }
        if summary.needsImmediateAttention || syncAttentionShown {
            cancelSyncAttentionTimer()
            setSyncAttention(shown: true)
            return
        }
        guard syncAttentionTask == nil else { return }
        syncAttentionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.syncAttentionDelay)
            guard !Task.isCancelled, let self else { return }
            self.syncAttentionTask = nil
            let latest = self.primaryPanelProvider?().sync ?? .off
            if latest.hasProblem && !latest.isSyncing { self.setSyncAttention(shown: true) }
        }
    }

    private func cancelSyncAttentionTimer() {
        syncAttentionTask?.cancel()
        syncAttentionTask = nil
    }

    private func setSyncAttention(shown: Bool) {
        syncAttentionShown = shown
        refreshGlyph()
    }

    /// Redraws the icon for the current pause, update and sync states, and refreshes the tooltip
    /// so it never goes stale.
    private func refreshGlyph() {
        let state = IconState(
            paused: capturePaused,
            updateText: footer.updateAttention(),
            syncProblem: syncAttentionShown
        )
        if state != renderedGlyphState {
            renderedGlyphState = state
            statusItem.button?.image = Self.glyph(for: state)
        }
        applyTooltip()
    }

    /// Spring-like scale bounce on the brand glyph confirming a capture (visual counterpart to the
    /// haptic/sound cue); skipped under Reduce Motion. Transforms explicitly rather than mutating
    /// `anchorPoint`, so the icon never drifts.
    private func pulseGlyph() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = statusItem.button?.layer, layer.bounds.width > 0 else { return }

        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        func scaled(_ s: CGFloat) -> NSValue {
            var t = CATransform3DTranslate(CATransform3DIdentity, center.x, center.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -center.x, -center.y, 0)
            return NSValue(caTransform3D: t)
        }

        let pulse = CAKeyframeAnimation(keyPath: "transform")
        // Overshoot, a hair of undershoot, then settle — reads as a spring without a physics solver.
        pulse.values = [scaled(1.0), scaled(YankMotion.capturePulseScale), scaled(0.98), scaled(1.0)]
        pulse.keyTimes = [0, 0.4, 0.7, 1.0]
        pulse.duration = YankMotion.capturePulseDuration
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        layer.add(pulse, forKey: "capturePulse")
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }

        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true   // layer-backed so the capture pulse can animate the glyph

        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Yank mark in full colour — light ground + amber arrow reads on both light and dark menu
    /// bars. `isTemplate = false` deliberately opts out of the system's monochrome template tint
    /// (which flattened it to a white blob), honouring the asset's `original` rendering intent.
    private static let brandGlyph: NSImage = {
        let image = NSImage(named: "BrandGlyph") ?? NSImage()
        image.isTemplate = false
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "Yank"
        return image
    }()

    private static let pausedTooltipLine = "Capture is paused"

    /// The brand glyph with the active marks, each in its own corner so none hides another: the
    /// update dot top-left, the sync dot top-right and the pause mark bottom-right. Dots carry a
    /// thin ring in the menu-bar ground colour, so they separate from the amber arrow and clear
    /// 3:1 against both a light and a dark menu bar. Drawn per appearance at render time.
    private static func glyph(for state: IconState) -> NSImage {
        let image = NSImage(size: brandGlyph.size, flipped: false) { rect in
            brandGlyph.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: state.paused ? PauseMark.glyphOpacity : 1
            )
            if state.updateText != nil {
                drawDot(
                    in: NSRect(
                        x: rect.minX + UpdateDot.ringWidth,
                        y: rect.maxY - UpdateDot.diameter - UpdateDot.ringWidth,
                        width: UpdateDot.diameter,
                        height: UpdateDot.diameter
                    ),
                    ringWidth: UpdateDot.ringWidth,
                    color: .yankSuccess
                )
            }
            if state.syncProblem {
                drawDot(
                    in: NSRect(
                        x: rect.maxX - AttentionDot.diameter - AttentionDot.inset,
                        y: rect.maxY - AttentionDot.diameter - AttentionDot.inset,
                        width: AttentionDot.diameter,
                        height: AttentionDot.diameter
                    ),
                    ringWidth: AttentionDot.ringWidth,
                    color: .yankDanger
                )
            }
            if state.paused {
                drawPauseMark(in: rect)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    private static func drawDot(in dotRect: NSRect, ringWidth: CGFloat, color: NSColor) {
        AttentionDot.ringColor.setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -ringWidth, dy: -ringWidth)).fill()
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    /// Two short bars on a small pill in the menu-bar ground colour, bottom-right.
    private static func drawPauseMark(in rect: NSRect) {
        let pill = NSRect(x: rect.maxX - PauseMark.width, y: rect.minY, width: PauseMark.width, height: PauseMark.height)
        AttentionDot.ringColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: PauseMark.cornerRadius, yRadius: PauseMark.cornerRadius).fill()
        let barsWidth = PauseMark.barWidth * 2 + PauseMark.barGap
        let barsOriginX = pill.midX - barsWidth / 2
        NSColor.labelColor.setFill()
        for index in 0..<2 {
            let bar = NSRect(
                x: barsOriginX + CGFloat(index) * (PauseMark.barWidth + PauseMark.barGap),
                y: pill.midY - PauseMark.barHeight / 2,
                width: PauseMark.barWidth,
                height: PauseMark.barHeight
            )
            NSBezierPath(roundedRect: bar, xRadius: PauseMark.barWidth / 2, yRadius: PauseMark.barWidth / 2).fill()
        }
    }

    private enum AttentionDot {
        static let diameter: CGFloat = 7
        static let ringWidth: CGFloat = 1.5
        static let inset: CGFloat = 0
        /// Close to the menu-bar ground in each appearance.
        static let ringColor = NSColor.yankDynamic(light: 0xF2F2F2, dark: 0x1E1E1E)
    }

    /// Smaller than the sync dot and in the opposite corner, so the two differ by place and size.
    private enum UpdateDot {
        static let diameter: CGFloat = 5
        static let ringWidth: CGFloat = 1
    }

    private enum PauseMark {
        static let width: CGFloat = 7
        static let height: CGFloat = 7
        static let cornerRadius: CGFloat = 2.5
        static let barWidth: CGFloat = 1.5
        static let barHeight: CGFloat = 4
        static let barGap: CGFloat = 1.5
        /// The logo is dimmed while paused, in addition to the drawn mark.
        static let glyphOpacity: CGFloat = 0.4
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            primaryPanelProvider?().onOpenQuickPicker()
            return
        }

        // A Control-click opens the menu as a right-click does; macOS may deliver it as either event.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            primaryPanelProvider?().onOpenQuickPicker()
        }
    }

    // MARK: - Command panel

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let pasteTargetApplication = NSWorkspace.shared.frontmostApplication
        // Close any panel still open before building a fresh one.
        dismissMenu()
        menuPasteTargetApplication = pasteTargetApplication
        // Pull fresh panel state at open time so clip count, pause state, and shortcut stay current.
        let panel = primaryPanelProvider?()

        let view = makeMenuView(
            panel: panel,
            pasteTargetApplication: pasteTargetApplication
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        menuPopover = popover
    }

    private func makeMenuView(
        panel: HubPrimaryPanel?,
        pasteTargetApplication: NSRunningApplication?
    ) -> StatusMenuView {
        StatusMenuView(
            shortcut: panel?.shortcut ?? "",
            shortcutOpenTarget: panel?.shortcutOpenTarget ?? .quickPicker,
            isPaused: panel?.isPaused ?? false,
            ignoreNextCopyArmed: panel?.ignoreNextCopyArmed ?? false,
            hotkeyUnavailable: panel?.hotkeyUnavailable ?? false,
            itemCount: panel?.itemCount ?? 0,
            isPasteSequenceActive: panel?.isPasteSequenceActive ?? false,
            pasteSequenceItemCount: panel?.pasteSequenceItemCount ?? 0,
            canRepeatPasteSequence: panel?.canRepeatPasteSequence ?? false,
            updateMenu: footer.updateMenu(),
            onOpenQuickPicker: { [weak self] in self?.dismissMenu(); panel?.onOpenQuickPicker() },
            onOpenHistory: { [weak self] in self?.dismissMenu(); panel?.onOpenHistory() },
            onTogglePasteSequence: { [weak self] in
                self?.dismissMenu()
                panel?.onTogglePasteSequence()
            },
            onRepeatPasteSequence: { [weak self] in
                self?.dismissMenu()
                panel?.onRepeatPasteSequence(pasteTargetApplication)
            },
            onTogglePause: { [weak self] in panel?.onTogglePause(); self?.dismissMenu() },
            onIgnoreNextCopy: { [weak self] in panel?.onIgnoreNextCopy(); self?.dismissMenu() },
            onFixShortcut: { [weak self] in self?.dismissMenu(); panel?.onFixShortcut() },
            onSettings: { [weak self] in self?.dismissMenu(); panel?.onSettings() },
            sync: panel?.sync ?? .off,
            // Stays open so the status line shows "Syncing…" and then the new time.
            onSyncNow: { panel?.onSyncNow() },
            onSyncOpenSettings: { [weak self] in self?.dismissMenu(); panel?.onSyncOpenSettings() },
            onUpdateAction: { [weak self] action in self?.performUpdateAction(action) },
            onClear: { [weak self] in self?.dismissMenu(); panel?.onClear() },
            onRestart: { [weak self] in self?.dismissMenu(); self?.footer.onRestart() },
            onQuit: { [weak self] in self?.footer.onQuit() }
        )
    }

    private func performUpdateAction(_ action: UpdateMenuActionID) {
        footer.onUpdateAction(action)
        switch action {
        case .cancel, .relaunch, .openReleaseNotes:
            dismissMenu()
        case .check, .install, .retry:
            refreshMenu()
        }
    }

    private func refreshMenu() {
        guard let popover = menuPopover, popover.isShown else { return }
        let panel = primaryPanelProvider?()
        if let controller = popover.contentViewController as? NSHostingController<StatusMenuView> {
            controller.rootView = makeMenuView(
                panel: panel,
                pasteTargetApplication: menuPasteTargetApplication
            )
        } else {
            popover.contentViewController = NSHostingController(
                rootView: makeMenuView(
                    panel: panel,
                    pasteTargetApplication: menuPasteTargetApplication
                )
            )
        }
    }

    private func dismissMenu() {
        menuPopover?.performClose(nil)
        menuPopover = nil
        menuPasteTargetApplication = nil
    }
}

/// The app-global footer the hub renders below clipboard actions: update controls,
/// restart, and quit. The update presentation is supplied as a closure so it is
/// pulled at menu-open and stays current.
@MainActor
struct HubAppFooter {
    let updateMenu: @MainActor () -> UpdateMenuPresentation
    let updateAttention: @MainActor () -> String?
    let onUpdateAction: @MainActor (UpdateMenuActionID) -> Void
    let onRestart: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
}
