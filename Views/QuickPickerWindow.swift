import Cocoa
import SwiftUI

@MainActor
final class QuickPickerPanel: NSPanel {
    var onClickOutside: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onClickOutside?()
    }
}

@MainActor
final class QuickPickerWindowController: NSWindowController, NSWindowDelegate {
    private let store: ClipboardStore
    private let settings: SettingsManager
    private let axPermission: AccessibilityPermission
    private let anchorFrameProvider: @MainActor () -> NSRect?
    private let focusedInputFrameProvider: @MainActor (NSRunningApplication?) -> NSRect?
    private let onOpenFullHistory: @MainActor () -> Void
    private var previousApp: NSRunningApplication?
    private var isApplyingProgrammaticFrame = false

    private static let defaultSize = NSSize(width: 392, height: 430)
    private static let frameDefaultsKey = "QuickPickerWindowFrame"

    init(
        store: ClipboardStore,
        settings: SettingsManager = .shared,
        axPermission: AccessibilityPermission,
        anchorFrameProvider: @escaping @MainActor () -> NSRect? = { nil },
        focusedInputFrameProvider: @escaping @MainActor (NSRunningApplication?) -> NSRect? = {
            FocusedInputFrameProvider.frame(preferredApp: $0)
        },
        onOpenFullHistory: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.axPermission = axPermission
        self.anchorFrameProvider = anchorFrameProvider
        self.focusedInputFrameProvider = focusedInputFrameProvider
        self.onOpenFullHistory = onOpenFullHistory

        let initialRect = Self.savedFrame() ?? NSRect(origin: .zero, size: Self.defaultSize)
        let panel = QuickPickerPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        panel.onClickOutside = { [weak self] in self?.close() }
        setupPanel(panel)
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func savedFrame() -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: frameDefaultsKey) else { return nil }
        let frame = NSRectFromString(value)
        guard frame.width >= 320, frame.height >= 320 else { return nil }
        return frame
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
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func setupContent() {
        let view = QuickPickerView(
            store: store,
            onPaste: { [weak self] item in self?.paste(item) },
            onPasteAsText: { [weak self] item in self?.pasteAsText(item) },
            onCopy: { [weak self] item in self?.copy(item) },
            onSmartPaste: { [weak self] item, transform in self?.smartPaste(item, transform) },
            onDismiss: { [weak self] in self?.close() },
            onOpenFullHistory: { [weak self] in self?.openFullHistory() },
            onSmartSearch: { [weak self] phrase in await self?.smartSearch(phrase) ?? [] }
        )
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.cornerRadius = Radius.window
        host.layer?.masksToBounds = true
        window?.contentView = host
    }

    override func showWindow(_ sender: Any?) {
        previousApp = NSWorkspace.shared.frontmostApplication
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
        guard notification.object as? NSWindow === window,
              !isApplyingProgrammaticFrame,
              window?.isVisible == true,
              let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)

        guard settings.quickPickerPlacement != .lastPosition else { return }
        settings.quickPickerPlacement = .lastPosition
        settings.save()
    }

    private func openFullHistory() {
        close()
        onOpenFullHistory()
    }

    private func smartSearch(_ phrase: String) async -> [ClipboardItem] {
        let query = await FoundationModelQueryParser().parse(phrase)
        return query.apply(to: store.filteredItems(search: "", activeTag: nil))
    }

    private func copy(_ item: ClipboardItem) {
        NotificationCenter.default.post(name: .yankIgnoreNextChange, object: nil)
        PasteController.copyToClipboard(item, store: store)
        close()
    }

    private func paste(_ item: ClipboardItem) {
        let appToRestore = previousApp
        close()
        NotificationCenter.default.post(name: .yankIgnoreNextChange, object: nil)
        DispatchQueue.main.async {
            PasteController.paste(item, store: self.store, axPermission: self.axPermission, previousApp: appToRestore)
        }
    }

    private func smartPaste(_ item: ClipboardItem, _ transform: TextTransform) {
        let appToRestore = previousApp
        close()
        NotificationCenter.default.post(name: .yankIgnoreNextChange, object: nil)
        PasteController.pasteTransformed(item, as: transform, store: store,
                                         axPermission: axPermission, previousApp: appToRestore)
    }

    private func pasteAsText(_ item: ClipboardItem) {
        guard let text = item.ocrText ?? item.textContent, !text.isEmpty else { return }
        let appToRestore = previousApp
        close()
        NotificationCenter.default.post(name: .yankIgnoreNextChange, object: nil)
        DispatchQueue.main.async {
            PasteController.pasteText(text, axPermission: self.axPermission, previousApp: appToRestore)
        }
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        if frame.width <= 1 || frame.height <= 1 {
            let point = NSPoint(x: frame.midX, y: frame.midY)
            return NSScreen.screens.first {
                $0.visibleFrame.contains(point) || $0.frame.contains(point)
            }
        }
        return NSScreen.screens.first { $0.visibleFrame.intersects(frame) || $0.frame.intersects(frame) }
    }

    private func fallbackScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func guardOnScreen(_ frame: NSRect, preferredScreen: NSScreen? = nil) -> NSRect {
        guard let visibleFrame = (preferredScreen ?? screen(containing: frame) ?? fallbackScreen())?.visibleFrame
        else { return frame }
        return HistoryWindowPlacementResolver.constrained(frame, to: visibleFrame)
    }

    private func openingFrame(for window: NSWindow) -> NSRect? {
        let windowSize = window.frame.size
        let anchorFrame = anchorFrameProvider()
        let anchorScreen = anchorFrame.flatMap { screen(containing: $0) }
        let focusedInputFrame = focusedInputFrameProvider(previousApp)
        let focusedInputScreen = focusedInputFrame.flatMap { screen(containing: $0) }
        let preferredScreen = focusedInputScreen ?? anchorScreen

        switch settings.quickPickerPlacement {
        case .focusedInput:
            if let focusedInputFrame,
               let screen = focusedInputScreen ?? fallbackScreen() {
                return HistoryWindowPlacementResolver.attachedToFocusedInput(
                    inputFrame: focusedInputFrame,
                    windowSize: windowSize,
                    visibleFrame: screen.visibleFrame
                )
            }
            return openingFrameForFirstRun(windowSize: windowSize, preferredScreen: preferredScreen)
        case .menuBarIcon:
            guard let anchorFrame,
                  let screen = screen(containing: anchorFrame) ?? fallbackScreen() else {
                return topRightFrame(windowSize: windowSize, preferredScreen: preferredScreen)
            }
            return HistoryWindowPlacementResolver.attachedToAnchor(
                anchorFrame: anchorFrame,
                windowSize: windowSize,
                visibleFrame: screen.visibleFrame
            )
        case .lastPosition:
            if let saved = Self.savedFrame() {
                return guardOnScreen(saved, preferredScreen: preferredScreen)
            }
            return openingFrameForFirstRun(windowSize: windowSize, preferredScreen: preferredScreen)
        case .center:
            return centeredFrame(windowSize: windowSize, preferredScreen: preferredScreen)
        case .topRight:
            return topRightFrame(windowSize: windowSize, preferredScreen: preferredScreen)
        }
    }

    private func openingFrameForFirstRun(windowSize: NSSize, preferredScreen: NSScreen?) -> NSRect? {
        if let anchorFrame = anchorFrameProvider(),
           let screen = screen(containing: anchorFrame) ?? fallbackScreen() {
            return HistoryWindowPlacementResolver.attachedToAnchor(
                anchorFrame: anchorFrame,
                windowSize: windowSize,
                visibleFrame: screen.visibleFrame
            )
        }
        return centeredFrame(windowSize: windowSize, preferredScreen: preferredScreen)
    }

    private func centeredFrame(windowSize: NSSize, preferredScreen: NSScreen?) -> NSRect? {
        guard let visibleFrame = (preferredScreen ?? fallbackScreen())?.visibleFrame else { return nil }
        return HistoryWindowPlacementResolver.centered(windowSize: windowSize, visibleFrame: visibleFrame)
    }

    private func topRightFrame(windowSize: NSSize, preferredScreen: NSScreen?) -> NSRect? {
        guard let visibleFrame = (preferredScreen ?? fallbackScreen())?.visibleFrame else { return nil }
        return HistoryWindowPlacementResolver.topRight(windowSize: windowSize, visibleFrame: visibleFrame)
    }

    private func applyOpeningFrame() {
        guard let window, let frame = openingFrame(for: window) else { return }
        window.setFrame(frame, display: false)
    }

    private func animateIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window else {
            window?.alphaValue = 1
            return
        }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = YankMotion.summonInDuration
            window.animator().alphaValue = 1
        }
    }
}
