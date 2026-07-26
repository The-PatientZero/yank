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
    }

    func setPrimaryPanelProvider(_ provider: (@MainActor () -> HubPrimaryPanel)?) {
        primaryPanelProvider = provider
    }

    func setPrimaryIconDimmed(_ dimmed: Bool) {
        statusItem.button?.alphaValue = dimmed ? 0.4 : 1.0
    }

    func setTooltip(_ text: String) {
        statusItem.button?.toolTip = text
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

    /// A quick spring-like scale bounce on the brand glyph to confirm a capture — the always-visible
    /// counterpart to the haptic/sound cue. Scales around the button's visual centre via an explicit
    /// transform (no `anchorPoint` mutation, so the icon never drifts) and is skipped entirely under
    /// Reduce Motion.
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
        // Left-click drives the primary action, right-click opens the command panel.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The Yank mark in full colour. The glyph is a self-contained tile — light ground + the
    /// amber brand arrow — so it reads on both light and dark menu bars without the system's
    /// monochrome template tint (which flattened it to a solid white blob). This honours the
    /// asset's own `template-rendering-intent: original`.
    private static let brandGlyph: NSImage = {
        let image = NSImage(named: "BrandGlyph") ?? NSImage()
        image.isTemplate = false
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "Yank"
        return image
    }()

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
