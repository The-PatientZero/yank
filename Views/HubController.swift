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

    init(footer: HubAppFooter, settings: SettingsManager = .shared) {
        self.footer = footer
        self.settings = settings
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
    }

    func setPrimaryPanelProvider(_ provider: (@MainActor () -> HubPrimaryPanel)?) {
        primaryPanelProvider = provider
    }

    func setPrimaryIconDimmed(_ dimmed: Bool) {
        statusItem.button?.alphaValue = dimmed ? 0.4 : 1.0
    }

    /// The tooltip is the shortcut line, then the sync problem while the icon shows its dot, then
    /// the hint, so the three never overwrite each other.
    func setTooltip(headline: String, syncProblem: String?, hint: String) {
        tooltipParts = (headline, syncProblem, hint)
        applyTooltip()
    }

    private func applyTooltip() {
        let lines = [tooltipParts.headline, syncAttentionShown ? tooltipParts.syncProblem : nil, tooltipParts.hint]
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
        let changed = shown != syncAttentionShown
        syncAttentionShown = shown
        if changed {
            statusItem.button?.image = shown ? Self.attentionGlyph : Self.brandGlyph
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

        button.image = Self.brandGlyph
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

    /// The brand glyph with a small dot in the top-right corner. The dot is the danger ink with a
    /// thin ring in the menu-bar ground colour, so it separates from the amber arrow and clears
    /// 3:1 against both a light and a dark menu bar. Drawn per appearance at render time.
    private static let attentionGlyph: NSImage = {
        let size = brandGlyph.size
        let image = NSImage(size: size, flipped: false) { rect in
            brandGlyph.draw(in: rect)
            let dotRect = NSRect(
                x: rect.maxX - AttentionDot.diameter - AttentionDot.inset,
                y: rect.maxY - AttentionDot.diameter - AttentionDot.inset,
                width: AttentionDot.diameter,
                height: AttentionDot.diameter
            )
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -AttentionDot.ringWidth, dy: -AttentionDot.ringWidth))
            AttentionDot.ringColor.setFill()
            ring.fill()
            NSColor.yankDanger.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Yank, sync problem"
        return image
    }()

    private enum AttentionDot {
        static let diameter: CGFloat = 7
        static let ringWidth: CGFloat = 1.5
        static let inset: CGFloat = 0
        /// Close to the menu-bar ground in each appearance.
        static let ringColor = NSColor.yankDynamic(light: 0xF2F2F2, dark: 0x1E1E1E)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            primaryPanelProvider?().onOpenQuickPicker()
            return
        }

        if event.type == .rightMouseUp {
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
    let onUpdateAction: @MainActor (UpdateMenuActionID) -> Void
    let onRestart: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
}
