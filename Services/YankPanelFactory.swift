import AppKit

private final class ActionableYankPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard let onCancel else {
            super.cancelOperation(sender)
            return
        }
        onCancel()
    }

    override func performClose(_ sender: Any?) {
        guard let onCancel else {
            super.performClose(sender)
            return
        }
        onCancel()
    }
}

enum YankPanelMode {
    case transient
    case dialog
}

enum YankPanelTextAlignment {
    case center
    case leading

    var text: NSTextAlignment {
        switch self {
        case .center:
            return .center
        case .leading:
            return .left
        }
    }

    var row: YankPanelRowAlignment {
        switch self {
        case .center:
            return .center
        case .leading:
            return .leading
        }
    }
}

enum YankPanelRowAlignment {
    case leading
    case center
    case trailing
}

enum YankPanelVerticalPlacement {
    case centered
    case top
}

enum YankPanelButtonStyle {
    case primary
    case secondary
    case quiet
}

enum YankPanelDetail {
    case note(String)
    case scrollable(String)

    var text: String {
        switch self {
        case let .note(text), let .scrollable(text):
            return text
        }
    }
}

struct YankPanelCardConfiguration {
    let symbolName: String
    let accentColor: NSColor
    let eyebrow: String?
    let title: String
    let message: String
    let detail: YankPanelDetail?
    let textAlignment: YankPanelTextAlignment
    let actionAlignment: YankPanelRowAlignment
    let verticalPlacement: YankPanelVerticalPlacement
    let actions: [NSButton]
    let showsSpinner: Bool

    init(
        symbolName: String,
        accentColor: NSColor,
        eyebrow: String? = nil,
        title: String,
        message: String,
        detail: YankPanelDetail? = nil,
        textAlignment: YankPanelTextAlignment = .leading,
        actionAlignment: YankPanelRowAlignment = .trailing,
        verticalPlacement: YankPanelVerticalPlacement = .top,
        actions: [NSButton],
        showsSpinner: Bool = false
    ) {
        self.symbolName = symbolName
        self.accentColor = accentColor
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
        self.detail = detail
        self.textAlignment = textAlignment
        self.actionAlignment = actionAlignment
        self.verticalPlacement = verticalPlacement
        self.actions = actions
        self.showsSpinner = showsSpinner
    }
}

@MainActor
enum YankPanelFactory {
    static func makePanel(
        size: NSSize,
        title: String = "Yank",
        mode: YankPanelMode = .transient
    ) -> (panel: NSPanel, content: NSVisualEffectView) {
        let styleMask: NSWindow.StyleMask
        switch mode {
        case .transient:
            styleMask = [.borderless]
        case .dialog:
            styleMask = [.titled, .closable, .fullSizeContentView]
        }
        let panel = ActionableYankPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityTitle(title)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = mode == .dialog ? .modalPanel : .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.center()
        if mode == .dialog {
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
        }

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

    static func setCancelAction(_ panel: NSPanel, action: @escaping () -> Void) {
        (panel as? ActionableYankPanel)?.onCancel = action
    }

    static func show(_ panel: NSPanel) {
        panel.makeKeyAndOrderFront(nil)
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

        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: YankPanelTokens.contentInset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -YankPanelTokens.contentInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -YankPanelTokens.contentInset)
        ]
        switch configuration.verticalPlacement {
        case .centered:
            constraints.append(contentsOf: [
                stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: YankPanelTokens.contentInset),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        case .top:
            constraints.append(stack.topAnchor.constraint(equalTo: content.topAnchor, constant: YankPanelTokens.contentInset))
        }
        NSLayoutConstraint.activate(constraints)

        let badge = makeBadge(
            symbolName: configuration.symbolName,
            accentColor: configuration.accentColor,
            showsSpinner: configuration.showsSpinner
        )
        let badgeRow = alignedRow(containing: badge, alignment: configuration.textAlignment.row)
        stack.addArrangedSubview(badgeRow)
        badgeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .width
        textStack.spacing = YankPanelTokens.tightStackSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(textStack)
        textStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if let eyebrow = configuration.eyebrow, !eyebrow.isEmpty {
            textStack.addArrangedSubview(makeLabel(
                eyebrow.uppercased(),
                font: YankPanelTokens.eyebrowFont,
                color: YankPanelTokens.tertiaryText,
                alignment: configuration.textAlignment.text,
                maximumNumberOfLines: 1
            ))
        }
        textStack.addArrangedSubview(makeLabel(
            configuration.title,
            font: YankPanelTokens.titleFont,
            color: YankPanelTokens.primaryText,
            alignment: configuration.textAlignment.text,
            maximumNumberOfLines: 2
        ))
        textStack.addArrangedSubview(makeLabel(
            configuration.message,
            font: YankPanelTokens.subtitleFont,
            color: YankPanelTokens.secondaryText,
            alignment: configuration.textAlignment.text,
            maximumNumberOfLines: 3
        ))

        if let detail = configuration.detail, !detail.text.isEmpty {
            let detailWell = makeDetailWell(detail, alignment: configuration.textAlignment.text)
            stack.addArrangedSubview(detailWell)
            detailWell.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if !configuration.actions.isEmpty {
            let actionStack = NSStackView(views: configuration.actions)
            actionStack.orientation = .horizontal
            actionStack.alignment = .centerY
            actionStack.spacing = Space.md
            actionStack.translatesAutoresizingMaskIntoConstraints = false

            let actionRow = alignedRow(containing: actionStack, alignment: configuration.actionAlignment)
            stack.addArrangedSubview(actionRow)
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    static func makeButton(
        title: String,
        style: YankPanelButtonStyle,
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

        switch style {
        case .primary:
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: YankPanelTokens.primaryButtonSize.height),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: YankPanelTokens.primaryButtonSize.width)
            ])
        case .secondary:
            button.bezelStyle = .rounded
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: YankPanelTokens.secondaryButtonSize.height),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: YankPanelTokens.secondaryButtonSize.width)
            ])
        case .quiet:
            button.bezelStyle = .inline
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: YankPanelTokens.quietButtonSize.height),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: YankPanelTokens.quietButtonSize.width)
            ])
        }
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
        case .center:
            constraints.append(view.centerXAnchor.constraint(equalTo: row.centerXAnchor))
            constraints.append(view.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor))
            constraints.append(view.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor))
        case .trailing:
            constraints.append(view.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private static func makeBadge(
        symbolName: String,
        accentColor: NSColor,
        showsSpinner: Bool
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

        if showsSpinner {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            badge.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Space.xs),
                spinner.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: Space.xs),
                spinner.widthAnchor.constraint(equalToConstant: YankPanelTokens.spinnerSize.width),
                spinner.heightAnchor.constraint(equalToConstant: YankPanelTokens.spinnerSize.height)
            ])
        }

        return badge
    }

    private static func makeDetailWell(_ detail: YankPanelDetail, alignment: NSTextAlignment) -> NSView {
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = Radius.md
        well.layer?.backgroundColor = YankPanelTokens.detailFill.cgColor
        well.translatesAutoresizingMaskIntoConstraints = false

        switch detail {
        case let .note(text):
            let label = makeLabel(
                text,
                font: YankPanelTokens.detailFont,
                color: YankPanelTokens.secondaryText,
                alignment: alignment,
                maximumNumberOfLines: 3
            )
            well.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Space.lg),
                label.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Space.lg),
                label.topAnchor.constraint(equalTo: well.topAnchor, constant: Space.md),
                label.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -Space.md)
            ])
        case let .scrollable(text):
            let scrollView = NSScrollView()
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            let textView = NSTextView()
            textView.string = text
            textView.font = YankPanelTokens.detailFont
            textView.textColor = YankPanelTokens.secondaryText
            textView.alignment = alignment
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: Space.sm, height: Space.sm)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.documentView = textView
            well.addSubview(scrollView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Space.md),
                scrollView.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Space.md),
                scrollView.topAnchor.constraint(equalTo: well.topAnchor, constant: Space.sm),
                scrollView.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -Space.sm),
                scrollView.heightAnchor.constraint(equalToConstant: YankPanelTokens.scrollableDetailHeight)
            ])
        }
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
