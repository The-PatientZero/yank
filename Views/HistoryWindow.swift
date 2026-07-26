import Cocoa
import SwiftUI
import QuartzCore

/// Custom panel that closes when clicking outside — unless suppressed (e.g. while the
/// in-window Settings screen is up, where clicking other apps must not dismiss it).
@MainActor
final class HistoryPanel: NSPanel {
    var onClickOutside: (() -> Void)?
    var settingsScreenIsActive = false
    var settings: SettingsManager = .shared

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        let policy = HistoryDismissalPolicy(
            keepsHistoryWindowOpen: settings.keepHistoryWindowOpen,
            settingsScreenIsActive: settingsScreenIsActive
        )
        guard policy.shouldDismissOnOutsideClick else { return }
        onClickOutside?()
    }
}

enum HistoryWindowPlacementResolver {
    static let menuBarGap: CGFloat = 8
    static let inputGap: CGFloat = 10
    static let screenPadding: CGFloat = 16
    static let narrowInputWidth: CGFloat = 12

    static func attachedToAnchor(anchorFrame: NSRect, windowSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let frame = NSRect(
            x: anchorFrame.midX - windowSize.width / 2,
            y: anchorFrame.minY - menuBarGap - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        return constrained(frame, to: visibleFrame)
    }

    static func centered(windowSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let frame = NSRect(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
        return constrained(frame, to: visibleFrame)
    }

    static func topRight(windowSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let frame = NSRect(
            x: visibleFrame.maxX - windowSize.width - screenPadding,
            y: visibleFrame.maxY - windowSize.height - screenPadding,
            width: windowSize.width,
            height: windowSize.height
        )
        return constrained(frame, to: visibleFrame)
    }

    static func attachedToFocusedInput(inputFrame: NSRect, windowSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let opensBelow = inputFrame.minY - visibleFrame.minY >= windowSize.height + inputGap
        let x = inputFrame.width <= narrowInputWidth
            ? inputFrame.midX - windowSize.width / 2
            : inputFrame.minX
        let y = opensBelow
            ? inputFrame.minY - inputGap - windowSize.height
            : inputFrame.maxY + inputGap
        let frame = NSRect(x: x, y: y, width: windowSize.width, height: windowSize.height)
        return constrained(frame, to: visibleFrame)
    }

    static func constrained(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var f = frame
        f.origin.x = max(visibleFrame.minX, min(f.origin.x, visibleFrame.maxX - f.width))
        f.origin.y = max(visibleFrame.minY, min(f.origin.y, visibleFrame.maxY - f.height))
        return f
    }
}

enum HistoryWindowFrameEvent {
    case userMove
    case userResize
    case close
}

enum HistoryWindowFramePersistencePolicy {
    static func shouldPersistFrame(
        for event: HistoryWindowFrameEvent,
        isApplyingProgrammaticFrame: Bool,
        isWindowVisible: Bool
    ) -> Bool {
        guard !isApplyingProgrammaticFrame, isWindowVisible else { return false }
        switch event {
        case .userMove, .userResize:
            return true
        case .close:
            return false
        }
    }

    static func placementAfterUserFrame(_ current: HistoryWindowPlacement) -> HistoryWindowPlacement {
        switch current {
        case .lastPosition:
            return current
        case .menuBarIcon, .center, .topRight:
            return .lastPosition
        }
    }
}

/// Manages the floating history window
@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let store: ClipboardStore
    private let settings: SettingsManager
    private let axPermission: AccessibilityPermission
    private let appStatus: AppStatus
    private let anchorFrameProvider: @MainActor () -> NSRect?
    private var previousApp: NSRunningApplication?
    private var didBecomeKeyObserver: NSObjectProtocol?

    /// Timestamp of the last close — used to decide whether to persist search state
    private var lastClosedAt: Date?
    /// Shared flag: true if the content view should reset search on the next open
    var shouldResetOnOpen: Bool = true
    /// Last selected item UUID — restored when reopening within the threshold
    var savedSelectedID: UUID?
    private let searchResetInterval: TimeInterval = 10 * 60

    /// Guards the summon-dismiss animation so a `resignKey` (or a paste-triggered close)
    /// mid-fade can't re-enter `close()` and stack a second animation.
    private var isAnimatingClose = false
    private var isApplyingProgrammaticFrame = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Reset search if window was closed more than 10 minutes ago (or never opened)
    private var shouldResetSearch: Bool {
        guard let lastClosed = lastClosedAt else { return true }
        return Date().timeIntervalSince(lastClosed) > searchResetInterval
    }

    private static let frameDefaultsKey = "HistoryWindowFrame"

    init(
        store: ClipboardStore,
        settings: SettingsManager = .shared,
        axPermission: AccessibilityPermission,
        appStatus: AppStatus,
        anchorFrameProvider: @escaping @MainActor () -> NSRect? = { nil }
    ) {
        self.store = store
        self.settings = settings
        self.axPermission = axPermission
        self.appStatus = appStatus
        self.anchorFrameProvider = anchorFrameProvider

        let initialRect = Self.savedFrame() ?? NSRect(x: 0, y: 0, width: 460, height: 640)
        let panel = HistoryPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.settings = settings

        super.init(window: panel)

        panel.onClickOutside = { [weak self] in
            self?.close()
        }

        setupPanel(panel)
        setupContent()
    }

    private static func savedFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: frameDefaultsKey) else { return nil }
        let r = NSRectFromString(str)
        guard r.width >= 360 && r.height >= 480 else { return nil }
        return r
    }

    private func persistFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(frame) || $0.frame.intersects(frame) }
    }

    private func fallbackScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func guardOnScreen(_ frame: NSRect, preferredScreen: NSScreen? = nil) -> NSRect {
        guard let visibleFrame = (preferredScreen ?? screen(containing: frame) ?? fallbackScreen())?.visibleFrame
        else { return frame }
        return HistoryWindowPlacementResolver.constrained(frame, to: visibleFrame)
    }

    private func frameAttachedToMenuBarIcon(windowSize: NSSize) -> NSRect? {
        guard let anchorFrame = anchorFrameProvider(),
              let screen = screen(containing: anchorFrame) ?? fallbackScreen() else { return nil }
        return HistoryWindowPlacementResolver.attachedToAnchor(
            anchorFrame: anchorFrame,
            windowSize: windowSize,
            visibleFrame: screen.visibleFrame
        )
    }

    private func topRightFrame(windowSize: NSSize, preferredScreen: NSScreen? = nil) -> NSRect? {
        guard let visibleFrame = (preferredScreen ?? fallbackScreen())?.visibleFrame else { return nil }
        return HistoryWindowPlacementResolver.topRight(windowSize: windowSize, visibleFrame: visibleFrame)
    }

    private func centeredFrame(windowSize: NSSize, preferredScreen: NSScreen? = nil) -> NSRect? {
        guard let visibleFrame = (preferredScreen ?? fallbackScreen())?.visibleFrame else { return nil }
        return HistoryWindowPlacementResolver.centered(windowSize: windowSize, visibleFrame: visibleFrame)
    }

    private func openingFrame(for window: NSWindow) -> NSRect? {
        let windowSize = window.frame.size
        let anchorFrame = anchorFrameProvider()
        let anchorScreen = anchorFrame.flatMap { screen(containing: $0) }

        switch settings.historyWindowPlacement {
        case .menuBarIcon:
            return frameAttachedToMenuBarIcon(windowSize: windowSize)
                ?? topRightFrame(windowSize: windowSize, preferredScreen: anchorScreen)
        case .lastPosition:
            if let saved = Self.savedFrame() {
                return guardOnScreen(saved)
            }
            return frameAttachedToMenuBarIcon(windowSize: windowSize)
                ?? centeredFrame(windowSize: windowSize, preferredScreen: anchorScreen)
        case .center:
            return centeredFrame(windowSize: windowSize, preferredScreen: anchorScreen)
        case .topRight:
            return topRightFrame(windowSize: windowSize, preferredScreen: anchorScreen)
        }
    }

    private func applyOpeningFrame() {
        guard let window, let frame = openingFrame(for: window) else { return }
        window.setFrame(frame, display: false)
    }

    private func persistUserFrameIfNeeded(for event: HistoryWindowFrameEvent) {
        guard HistoryWindowFramePersistencePolicy.shouldPersistFrame(
            for: event,
            isApplyingProgrammaticFrame: isApplyingProgrammaticFrame,
            isWindowVisible: window?.isVisible == true
        ) else { return }
        persistFrame()
        guard settings.historyWindowPlacement != .lastPosition else { return }
        settings.historyWindowPlacement = HistoryWindowFramePersistencePolicy
            .placementAfterUserFrame(settings.historyWindowPlacement)
        settings.save()
    }

    override func close() {
        guard !isAnimatingClose else { return }
        persistUserFrameIfNeeded(for: .close)
        lastClosedAt = Date()
        // Reduce Motion (or no backing layer / already-hidden) → close instantly.
        guard !reduceMotion, let window, window.isVisible,
              let layer = window.contentView?.layer else {
            super.close()
            return
        }
        isAnimatingClose = true
        let timing = Self.summonTiming

        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: Self.centerScale(layer, YankMotion.summonScale))
        shrink.duration = YankMotion.summonOutDuration
        shrink.timingFunction = timing

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.isAnimatingClose else { return }  // a re-show cancelled it
            self.isAnimatingClose = false
            self.window?.contentView?.layer?.removeAnimation(forKey: Self.summonKey)
            self.performActualClose()
        }
        layer.add(shrink, forKey: Self.summonKey)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = YankMotion.summonOutDuration
            ctx.timingFunction = timing
            window.animator().alphaValue = 0
        }
        CATransaction.commit()
    }

    /// Actually orders the window out, once the dismiss animation completes. Lives in its
    /// own method so it can be invoked from the animation's escaping completion block.
    private func performActualClose() {
        super.close()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // `isolated deinit` runs cleanup on the main actor (the runtime hops if the last release lands
    // off-main), so it never traps the way `MainActor.assumeIsolated` would, while still allowing
    // access to the non-Sendable observer token.
    isolated deinit {
        if let token = didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func setupPanel(_ panel: NSPanel) {
        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true

        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = Radius.window
        panel.contentView?.layer?.masksToBounds = true
        
        panel.center()
        
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        
        // Notify content view when window becomes key so it can reset state
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .yankWindowDidOpen, object: nil)
        }
    }
    
    private func setupContent() {
        let contentView = HistoryContentView(
            store: store,
            axPermission: axPermission,
            settings: settings,
            shouldResetOnOpen: Binding(
                get: { [weak self] in self?.shouldResetOnOpen ?? true },
                set: { [weak self] newValue in self?.shouldResetOnOpen = newValue }
            ),
            savedSelectedID: Binding(
                get: { [weak self] in self?.savedSelectedID },
                set: { [weak self] newValue in self?.savedSelectedID = newValue }
            ),
            onCopyToClipboard: { [weak self] item in
                self?.copyToClipboard(item)
            },
            onCopyMultipleToClipboard: { [weak self] items in
                self?.copyToClipboard(items)
            },
            onPaste: { [weak self] item in
                self?.pasteItem(item)
            },
            onPasteAsText: { [weak self] item in
                self?.pasteItemAsText(item)
            },
            onPasteMultiple: { [weak self] items in
                self?.pasteMultiple(items)
            },
            onDismiss: { [weak self] in
                self?.close()
            },
            onSettingsActiveChange: { [weak self] active in
                (self?.window as? HistoryPanel)?.settingsScreenIsActive = active
            },
            appStatus: appStatus
        )

        let host = NSHostingView(rootView: contentView)
        window?.contentView = host
        // The corner-radius set in `setupPanel` targeted the panel's original contentView,
        // which this assignment replaces — so clip the real hosting layer here. It also gives
        // the summon scale+fade a rounded layer to transform cleanly.
        host.wantsLayer = true
        host.layer?.cornerRadius = Radius.window
        host.layer?.masksToBounds = true
    }

    /// Open the window and navigate to the in-window Settings screen.
    func openSettings() {
        showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .yankOpenSettings, object: nil)
        }
    }
    
    private func copyToClipboard(_ item: ClipboardItem) {
        PasteController.copyToClipboard(item, store: store)
    }

    private func copyToClipboard(_ items: [ClipboardItem]) {
        PasteController.copyMultipleToClipboard(items, store: store)
    }
    
    private var pasteDelay: TimeInterval {
        reduceMotion ? 0 : YankMotion.summonOutDuration
    }

    private func pasteItem(_ item: ClipboardItem) {
        let appToRestore = previousApp
        let ax = axPermission
        let delay = pasteDelay
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            PasteController.paste(item, store: self.store, axPermission: ax, previousApp: appToRestore)
        }
    }

    private func pasteItemAsText(_ item: ClipboardItem) {
        guard let text = item.ocrText ?? item.textContent, !text.isEmpty else { return }
        let appToRestore = previousApp
        let ax = axPermission
        let delay = pasteDelay
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            PasteController.pasteText(text, axPermission: ax, previousApp: appToRestore)
        }
    }

    private func pasteMultiple(_ items: [ClipboardItem]) {
        let appToRestore = previousApp
        let ax = axPermission
        let delay = pasteDelay
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            PasteController.pasteMultiple(items, store: self.store, axPermission: ax, previousApp: appToRestore)
        }
    }
    
    override func showWindow(_ sender: Any?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        shouldResetOnOpen = shouldResetSearch
        isAnimatingClose = false
        window?.contentView?.layer?.removeAnimation(forKey: Self.summonKey)
        isApplyingProgrammaticFrame = true
        applyOpeningFrame()

        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
        isApplyingProgrammaticFrame = false
        animateIn()
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        persistUserFrameIfNeeded(for: .userMove)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        persistUserFrameIfNeeded(for: .userResize)
    }

    // MARK: - Summon animation (Spotlight/Raycast-style scale + fade)

    private static let summonKey = "yankSummon"

    private static var summonTiming: CAMediaTimingFunction {
        let p = YankMotion.expoOutControlPoints
        return CAMediaTimingFunction(controlPoints: p.x1, p.y1, p.x2, p.y2)
    }

    /// A uniform scale built to pivot on the layer's geometric centre regardless of its
    /// `anchorPoint`, so we never mutate `anchorPoint`/`position` (which AppKit owns and
    /// recomputes on resize). `translate(d) · scale(s) · translate(-d)` where `d` is the
    /// offset from the anchor to the centre.
    private static func centerScale(_ layer: CALayer, _ scale: CGFloat) -> CATransform3D {
        let bounds = layer.bounds
        let anchor = layer.anchorPoint
        let dx = (0.5 - anchor.x) * bounds.width
        let dy = (0.5 - anchor.y) * bounds.height
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, dx, dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -dx, -dy, 0)
        return t
    }

    private func animateIn() {
        guard !reduceMotion, let window, let layer = window.contentView?.layer else {
            window?.alphaValue = 1
            return
        }
        let timing = Self.summonTiming
        window.alphaValue = 0

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Self.centerScale(layer, YankMotion.summonScale))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = YankMotion.summonInDuration
        grow.timingFunction = timing
        layer.transform = CATransform3DIdentity   // model rests at the end state
        layer.add(grow, forKey: Self.summonKey)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = YankMotion.summonInDuration
            ctx.timingFunction = timing
            window.animator().alphaValue = 1
        }
    }
}
