import AppKit

/// A status card panel that never takes keyboard focus from the user's app.
private final class PassiveYankPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum YankPanelRowAlignment {
    case leading
    case trailing
}

struct YankPanelCardConfiguration {
    let symbolName: String
    let accentColor: NSColor
    let title: String
    let message: String
    let detail: String?
    let actions: [NSButton]

    init(
        symbolName: String,
        accentColor: NSColor,
        title: String,
        message: String,
        detail: String? = nil,
        actions: [NSButton]
    ) {
        self.symbolName = symbolName
        self.accentColor = accentColor
        self.title = title
        self.message = message
        self.detail = detail
        self.actions = actions
    }
}

@MainActor
enum YankPanelFactory {
    /// A status card that never becomes key, floats over full-screen apps and sits at the bottom
    /// centre of the screen holding `anchorApp`'s frontmost window (else the main screen).
    static func makePanel(
        size: NSSize,
        title: String = "Yank",
        anchorApp: NSRunningApplication?
    ) -> (panel: NSPanel, content: NSVisualEffectView) {
        let panel = PassiveYankPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityTitle(title)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setFrameOrigin(passiveOrigin(for: size, anchorApp: anchorApp))

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.blendingMode = .behindWindow
        content.material = panelMaterial
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = YankPanelTokens.cornerRadius
        content.layer?.borderWidth = panelBorderWidth
        content.layer?.borderColor = YankPanelTokens.panelStroke.cgColor
        content.layer?.backgroundColor = panelSurfaceColor.cgColor
        content.layer?.masksToBounds = true
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel(title)
        panel.contentView = content
        return (panel, content)
    }

    static func show(_ panel: NSPanel) {
        panel.orderFrontRegardless()
    }

    /// Distance between a passive card and the bottom edge of the visible screen area.
    private static let passiveBottomInset: CGFloat = 48

    private static func passiveOrigin(for size: NSSize, anchorApp: NSRunningApplication?) -> NSPoint {
        let visibleFrame = screen(holding: anchorApp)?.visibleFrame ?? .zero
        return NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + passiveBottomInset
        )
    }

    /// The screen showing the app's frontmost on-screen window, else the main screen.
    private static func screen(holding app: NSRunningApplication?) -> NSScreen? {
        if let app,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
           let bounds = windows.first(where: {
               ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                   && ($0[kCGWindowLayer as String] as? Int) == 0
           }).flatMap({ $0[kCGWindowBounds as String] as? NSDictionary }),
           let rect = CGRect(dictionaryRepresentation: bounds) {
            // Window bounds use a top-left origin on the primary display; flip into AppKit space.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = NSPoint(x: rect.midX, y: primaryHeight - rect.midY)
            if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return match
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func fadeIn(_ window: NSWindow) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = YankPanelTokens.fadeInDuration
            window.animator().alphaValue = 1
        }
    }

    static func fadeOut(_ window: NSWindow, completion: @escaping @MainActor () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.alphaValue = 0
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = YankPanelTokens.fadeOutDuration
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in completion() }
        }
    }

    static func populateCard(content: NSView, configuration: YankPanelCardConfiguration) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = YankPanelTokens.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: YankPanelTokens.contentInset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -YankPanelTokens.contentInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -YankPanelTokens.contentInset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: YankPanelTokens.contentInset)
        ])
        let badge = makeBadge(symbolName: configuration.symbolName, accentColor: configuration.accentColor)
        let badgeRow = alignedRow(containing: badge, alignment: .leading)
        stack.addArrangedSubview(badgeRow)
        badgeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .width
        textStack.spacing = YankPanelTokens.tightStackSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textStack)
        textStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        textStack.addArrangedSubview(makeLabel(
            configuration.title,
            font: YankPanelTokens.titleFont,
            color: YankPanelTokens.primaryText,
            alignment: .left,
            maximumNumberOfLines: 2
        ))
        textStack.addArrangedSubview(makeLabel(
            configuration.message,
            font: YankPanelTokens.subtitleFont,
            color: YankPanelTokens.secondaryText,
            alignment: .left,
            maximumNumberOfLines: 3
        ))

        if let detail = configuration.detail, !detail.isEmpty {
            let detailWell = makeDetailWell(detail)
            stack.addArrangedSubview(detailWell)
            detailWell.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if !configuration.actions.isEmpty {
            let actionStack = NSStackView(views: configuration.actions)
            actionStack.orientation = .horizontal
            actionStack.alignment = .centerY
            actionStack.spacing = Space.md
            actionStack.translatesAutoresizingMaskIntoConstraints = false

            let actionRow = alignedRow(containing: actionStack, alignment: .trailing)
            stack.addArrangedSubview(actionRow)
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    static func makeButton(
        title: String,
        target: AnyObject,
        action: Selector,
        accessibilityLabel: String,
        accessibilityHelp: String? = nil
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.font = YankPanelTokens.buttonFont
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(accessibilityLabel)
        if let accessibilityHelp {
            button.setAccessibilityHelp(accessibilityHelp)
        }
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: YankPanelTokens.primaryButtonSize.height),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: YankPanelTokens.primaryButtonSize.width)
        ])
        return button
    }

    private static var panelMaterial: NSVisualEffectView.Material {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .windowBackground : .popover
    }

    private static var panelSurfaceColor: NSColor {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = reduced ? 1 : (highContrast ? 0.95 : 0.82)
        return NSColor.yankDynamic(light: YankInk.raised.light, dark: YankInk.raised.dark).withAlphaComponent(alpha)
    }

    private static var panelBorderWidth: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : Hairline.width
    }

    private static func alignedRow(containing view: NSView, alignment: YankPanelRowAlignment) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)

        var constraints = [
            view.topAnchor.constraint(equalTo: row.topAnchor),
            view.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ]
        switch alignment {
        case .leading:
            constraints.append(view.leadingAnchor.constraint(equalTo: row.leadingAnchor))
        case .trailing:
            constraints.append(view.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private static func makeBadge(
        symbolName: String,
        accentColor: NSColor
    ) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = Radius.lg
        badge.layer?.backgroundColor = YankPanelTokens.badgeFill.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = configuredSymbol(symbolName, accentColor: accentColor)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityHidden(true)
        badge.addSubview(iconView)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: YankPanelTokens.badgeSize.width),
            badge.heightAnchor.constraint(equalToConstant: YankPanelTokens.badgeSize.height),
            iconView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: YankPanelTokens.badgeSize.width - Space.lg),
            iconView.heightAnchor.constraint(equalToConstant: YankPanelTokens.badgeSize.height - Space.lg)
        ])

        return badge
    }

    private static func makeDetailWell(_ text: String) -> NSView {
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = Radius.md
        well.layer?.backgroundColor = YankPanelTokens.detailFill.cgColor
        well.translatesAutoresizingMaskIntoConstraints = false

        let label = makeLabel(
            text,
            font: YankPanelTokens.detailFont,
            color: YankPanelTokens.secondaryText,
            alignment: .left,
            maximumNumberOfLines: 3
        )
        well.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Space.lg),
            label.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Space.lg),
            label.topAnchor.constraint(equalTo: well.topAnchor, constant: Space.md),
            label.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -Space.md)
        ])
        return well
    }

    private static func configuredSymbol(_ name: String, accentColor: NSColor) -> NSImage? {
        let pointSize = YankPanelTokens.badgeSize.width * YankPanelTokens.symbolPointScale
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [YankPanelTokens.primaryText, accentColor]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private static func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        maximumNumberOfLines: Int
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maximumNumberOfLines
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
