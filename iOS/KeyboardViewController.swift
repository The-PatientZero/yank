import SwiftUI
import UIKit
import os

private enum KeyboardMotion {
    static let pressDuration: TimeInterval = 0.14
}

/// A clip kind that gets its own filter chip.
private enum KindFilter: CaseIterable {
    case link, code, email, phone, swatch, note

    init?(_ kind: ClipKind) {
        switch kind {
        case .link:   self = .link
        case .code:   self = .code
        case .email:  self = .email
        case .phone:  self = .phone
        case .color:  self = .swatch
        case .note:   self = .note
        case .image:  return nil
        }
    }

    var title: String {
        switch self {
        case .link:   return "Links"
        case .code:   return "Code"
        case .email:  return "Email"
        case .phone:  return "Phone"
        case .swatch: return "Swatches"
        case .note:   return "Notes"
        }
    }
}

/// What the chip row can narrow the list to. Identity is the case, never the chip title.
private enum KeyboardFilter: Hashable {
    case all
    case pinned
    case bookmarked
    case kind(KindFilter)

    var title: String {
        switch self {
        case .all:               return "All"
        case .pinned:            return "Pinned"
        case .bookmarked:        return "Bookmarked"
        case let .kind(filter):  return filter.title
        }
    }
}

/// A clip the keyboard can list, with its kind worked out once per render.
private struct ListedClip {
    let item: ClipboardItem
    let kindFilter: KindFilter?

    func matches(_ filter: KeyboardFilter) -> Bool {
        switch filter {
        case .all:               return true
        case .pinned:            return item.isPinned
        case .bookmarked:        return item.isBookmarked
        case let .kind(filter):  return kindFilter == filter
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private static let log = Logger(subsystem: "com.thepatientzero.yank", category: "keyboard")
    private let appGroup = AppGroupContainer.live()
    private var items: [ClipboardItem] = []
    private var listedClips: [ListedClip] = []
    /// Kept in memory only: it survives a switch to another keyboard while the process lives.
    private var selectedFilter: KeyboardFilter = .all
    private var chipButtons: [(filter: KeyboardFilter, button: FilterChipButton)] = []

    private let maxVisibleClips = 10

    private static let baseKeyboardHeight: CGFloat = 180
    /// Largest factor the keyboard height may grow to at large text sizes, so it never outgrows
    /// an iPhone held in landscape.
    private static let maxKeyboardHeightScale: CGFloat = 1.5
    /// Room the switch-keyboard footer takes while it shows: one touch target plus its padding.
    private static let switchKeyFooterHeight = ControlTarget.touch + 2 * Space.sm

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let footerStack = UIStackView()
    private let switchKeyContainer = UIView()
    private var heightConstraint: NSLayoutConstraint?
    private var statusHost: UIHostingController<KeyboardStatusView>?
    private let resultsStack = UIStackView()
    private lazy var switchButton: SwitchKeyButton = makeSwitchButton()

    private enum Metrics {
        static let rowCornerRadius = Radius.md
    }

    private var rowBackground: UIColor { UIColor(Color.yankRaised) }
    private var rowBorder: UIColor { UIColor(Color.yankHairline) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Color.yankSurface)
        configureLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: KeyboardViewController, _) in
            controller.updateKeyboardHeight()
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scrollView.flashScrollIndicators()
        render()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The system can change its answer when the keyboard is docked, undocked or resized.
        syncSwitchKey()
    }

    // MARK: - Layout scaffold

    private func configureLayout() {
        let heightConstraint = view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.baseKeyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        self.heightConstraint = heightConstraint
        updateKeyboardHeight()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .none
        scrollView.showsVerticalScrollIndicator = true
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Space.sm
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Space.sm,
            leading: Space.md,
            bottom: Space.sm,
            trailing: Space.md
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        resultsStack.axis = .vertical
        resultsStack.alignment = .fill
        resultsStack.spacing = Space.sm
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        // The footer is always in the hierarchy; hiding its only child collapses it to no height.
        footerStack.axis = .vertical
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        switchKeyContainer.translatesAutoresizingMaskIntoConstraints = false
        switchKeyContainer.isHidden = true
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        switchKeyContainer.addSubview(switchButton)
        footerStack.addArrangedSubview(switchKeyContainer)
        view.addSubview(footerStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor),
            footerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            switchButton.leadingAnchor.constraint(equalTo: switchKeyContainer.leadingAnchor, constant: Space.md),
            switchButton.trailingAnchor.constraint(equalTo: switchKeyContainer.trailingAnchor, constant: -Space.md),
            switchButton.topAnchor.constraint(equalTo: switchKeyContainer.topAnchor, constant: Space.sm),
            switchButton.bottomAnchor.constraint(equalTo: switchKeyContainer.bottomAnchor, constant: -Space.sm),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    /// Scales the minimum height with the text size, up to a cap, and makes room for the footer
    /// while the switch-keyboard button shows.
    private func updateKeyboardHeight() {
        let base = Self.baseKeyboardHeight
        let scaled = min(
            UIFontMetrics.default.scaledValue(for: base, compatibleWith: traitCollection),
            base * Self.maxKeyboardHeightScale
        )
        let footer = switchKeyContainer.isHidden ? 0 : Self.switchKeyFooterHeight
        heightConstraint?.constant = scaled + footer
    }

    /// Shows the switch-keyboard button exactly when the system asks the keyboard to draw one.
    private func syncSwitchKey() {
        let needed = needsInputModeSwitchKey
        guard switchKeyContainer.isHidden == needed else { return }
        switchKeyContainer.isHidden = !needed
        updateKeyboardHeight()
    }

    // MARK: - State machine

    private func render() {
        defer { syncSwitchKey() }
        teardownStatusCard()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipButtons = []
        listedClips = []

        guard reloadHistory() else {
            presentStatusCard(.storageError)
            return
        }

        listedClips = KeyboardClipSearch.listableItems(from: items).map {
            ListedClip(item: $0, kindFilter: KindFilter($0.kind))
        }
        if listedClips.isEmpty {
            presentStatusCard(.empty)
            return
        }

        let filters = availableFilters()
        if !filters.contains(selectedFilter) { selectedFilter = .all }
        stack.addArrangedSubview(buildChipRow(filters))
        stack.addArrangedSubview(resultsStack)
        showSelectedList()
    }

    /// All, then Pinned and Bookmarked, then one chip per kind present. A chip with no clips is left out.
    private func availableFilters() -> [KeyboardFilter] {
        var filters: [KeyboardFilter] = [.all]
        if listedClips.contains(where: { $0.item.isPinned }) { filters.append(.pinned) }
        if listedClips.contains(where: { $0.item.isBookmarked }) { filters.append(.bookmarked) }
        let presentKinds = Set(listedClips.compactMap(\.kindFilter))
        filters += KindFilter.allCases.filter(presentKinds.contains).map(KeyboardFilter.kind)
        return filters
    }

    /// All keeps the newest few clips; any other chip lists every matching clip that was loaded.
    private func clipsForSelectedFilter() -> [ClipboardItem] {
        let matching = listedClips.lazy.filter { $0.matches(self.selectedFilter) }.map(\.item)
        return selectedFilter == .all ? Array(matching.prefix(maxVisibleClips)) : Array(matching)
    }

    @discardableResult
    private func showSelectedList() -> Int {
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let clips = clipsForSelectedFilter()
        for item in clips {
            resultsStack.addArrangedSubview(clipRow(for: item))
        }
        return clips.count
    }

    private func select(_ filter: KeyboardFilter) {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        for chip in chipButtons {
            chip.button.isSelected = chip.filter == filter
        }
        let count = showSelectedList()
        // Chips give visual and spoken feedback only: haptics do not fire without Full Access.
        UIAccessibility.post(notification: .announcement, argument: count == 1 ? "1 clip" : "\(count) clips")
    }

    /// The keyboard is intentionally a read-only App Group consumer. It reads the host's bounded
    /// projection and the small previews of queued short texts, without creating directories and
    /// without decoding the pending queue or its payloads.
    private func reloadHistory() -> Bool {
        guard let appGroup else {
            items = []
            Self.log.error("App Group container is unavailable; keyboard history cannot be read.")
            return false
        }
        do {
            let inbox = appGroup.shareInbox
            let log = Self.log
            items = try KeyboardHistoryReader(
                projectionURL: appGroup.keyboardProjectionURL,
                previewsURL: inbox.previewsURL,
                inboxEntriesURL: inbox.entriesURL,
                reportSkippedPreviews: { count in
                    log.error("Skipped \(count, privacy: .public) unreadable shared-text previews.")
                }
            ).load()
            return true
        } catch {
            items = []
            Self.log.error("Failed to read keyboard history: \(error.localizedDescription)")
            return false
        }
    }

    private func presentStatusCard(_ mode: KeyboardStatusView.Mode) {
        let host = UIHostingController(rootView: KeyboardStatusView(mode: mode))
        host.view.backgroundColor = .clear
        addChild(host)
        stack.addArrangedSubview(host.view)
        host.didMove(toParent: self)
        statusHost = host
    }

    private func teardownStatusCard() {
        guard let host = statusHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        statusHost = nil
    }

    // MARK: - Filter chips

    private func buildChipRow(_ filters: [KeyboardFilter]) -> UIView {
        let chips = UIStackView()
        chips.axis = .horizontal
        chips.alignment = .fill
        chips.spacing = Space.sm
        chips.translatesAutoresizingMaskIntoConstraints = false

        for filter in filters {
            let chip = FilterChipButton(title: filter.title)
            chip.isSelected = filter == selectedFilter
            chip.addAction(UIAction { [weak self] _ in self?.select(filter) }, for: .touchUpInside)
            installPressFeedback(on: chip)
            chips.addArrangedSubview(chip)
            chipButtons.append((filter, chip))
        }

        let row = UIScrollView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.showsHorizontalScrollIndicator = false
        row.alwaysBounceHorizontal = false
        row.addSubview(chips)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: row.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: row.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: row.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: row.contentLayoutGuide.bottomAnchor),
            row.frameLayoutGuide.heightAnchor.constraint(equalTo: row.contentLayoutGuide.heightAnchor)
        ])
        return row
    }

    // MARK: - Clip row

    private func clipRow(for item: ClipboardItem) -> UIControl {
        let row = ClipRowControl(item: item, background: rowBackground, border: rowBorder)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true
        row.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            if item.holdsOnlyPreview {
                // Haptics do not fire without Full Access, so the response is visual and spoken.
                row?.flashPreviewOnlyHint(accent: self.view.tintColor)
                UIAccessibility.post(notification: .announcement, argument: ClipRowControl.previewOnlyAnnouncement)
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            row?.flashInserted(accent: self.view.tintColor)
            self.textDocumentProxy.insertText(item.textContent ?? "")
        }, for: .touchUpInside)
        return row
    }

    // MARK: - Switch keyboard

    private func makeSwitchButton() -> SwitchKeyButton {
        let button = SwitchKeyButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Switch Keyboard"
        configuration.image = UIImage(systemName: "globe")
        configuration.imagePadding = Space.sm
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Space.sm,
            leading: Space.lg,
            bottom: Space.sm,
            trailing: Space.lg
        )
        configuration.background.backgroundColor = UIColor(Color.yankRaised).withAlphaComponent(0.6)
        configuration.background.cornerRadius = Metrics.rowCornerRadius
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .footnote)
            return outgoing
        }
        button.configuration = configuration
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true
        button.accessibilityLabel = "Switch keyboard"
        // The system selector switches on a tap and shows the keyboard list on a long press.
        button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        // VoiceOver activates without a touch event, which the system selector cannot act on.
        button.onAccessibilityActivate = { [weak self] in self?.advanceToNextInputMode() }
        installPressFeedback(on: button)
        return button
    }

    private func installPressFeedback(on button: UIButton) {
        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            if UIAccessibility.isReduceMotionEnabled {
                button.alpha = 0.85
                return
            }
            UIView.animate(withDuration: KeyboardMotion.pressDuration, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                button.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
                button.alpha = 0.85
            }
        }, for: .touchDown)

        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            if UIAccessibility.isReduceMotionEnabled {
                button.transform = .identity
                button.alpha = 1
                return
            }
            UIView.animate(withDuration: KeyboardMotion.pressDuration, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                button.transform = .identity
                button.alpha = 1
            }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }
}

/// The switch-keyboard button. Touches go to the system's input-mode-list handler; VoiceOver
/// activation, which carries no touch event, advances to the next keyboard directly.
private final class SwitchKeyButton: UIButton {
    var onAccessibilityActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onAccessibilityActivate else { return super.accessibilityActivate() }
        onAccessibilityActivate()
        return true
    }
}

/// One filter chip. Its selected state is drawn and spoken ("selected").
private final class FilterChipButton: UIButton {
    init(title: String) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Space.sm,
            leading: Space.lg,
            bottom: Space.sm,
            trailing: Space.lg
        )
        configuration.background.cornerRadius = Radius.md
        configuration.background.strokeWidth = Hairline.width
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .footnote)
            return outgoing
        }
        self.configuration = configuration
        configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = button.isSelected ? .label : .secondaryLabel
            updated?.background.backgroundColor = UIColor(button.isSelected ? Color.yankMultiSelect : Color.yankRaised)
            updated?.background.strokeColor = UIColor(button.isSelected ? Color.yankMultiSelectBorder : Color.yankHairline)
            button.configuration = updated
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits = super.accessibilityTraits.union(.button)
            if isSelected { traits.insert(.selected) }
            return traits
        }
        set { super.accessibilityTraits = newValue }
    }
}

private final class ClipRowControl: UIControl {
    private let restingColor: UIColor
    private let glyphView = UIImageView()
    private let excerptLabel = UILabel()
    private let ageLabel = UILabel()
    /// Second line on preview-only rows; created only for them to keep normal rows light.
    private var previewOnlyHintLabel: UILabel?
    /// Holds the excerpt, the preview-only hint when there is one, and the age at accessibility sizes.
    private let textColumn = UIStackView()
    private let content = UIStackView()
    /// Whether the age sits under the excerpt (accessibility text sizes) instead of beside it.
    private var isAgeStacked: Bool?

    static let previewOnlyAnnouncement = "Too large to insert. Open Yank to copy it."

    init(item: ClipboardItem, background: UIColor, border: UIColor) {
        self.restingColor = background
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = background
        layer.cornerRadius = Radius.md
        layer.borderColor = border.cgColor
        layer.borderWidth = Hairline.width

        let kind = item.kind
        glyphView.image = UIImage(systemName: kind.glyph)
        glyphView.tintColor = .secondaryLabel
        glyphView.contentMode = .scaleAspectFit
        glyphView.setContentHuggingPriority(.required, for: .horizontal)
        glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)

        excerptLabel.text = rowTitle(for: item, kind: kind)
        excerptLabel.font = .preferredFont(forTextStyle: .callout)
        excerptLabel.adjustsFontForContentSizeCategory = true
        excerptLabel.textColor = .label
        excerptLabel.numberOfLines = 1
        excerptLabel.lineBreakMode = .byTruncatingTail
        excerptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        ageLabel.text = item.relativeAge
        ageLabel.font = .preferredFont(forTextStyle: .caption2)
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.textColor = UIColor(Color.yankTextTertiary)
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textColumn.axis = .vertical
        textColumn.alignment = .fill
        textColumn.spacing = Space.xs
        textColumn.addArrangedSubview(excerptLabel)
        if item.holdsOnlyPreview {
            excerptLabel.textColor = .secondaryLabel
            let hint = UILabel()
            hint.text = "Open Yank to paste"
            hint.font = .preferredFont(forTextStyle: .caption2)
            hint.adjustsFontForContentSizeCategory = true
            hint.textColor = UIColor(Color.yankTextTertiary)
            hint.numberOfLines = 1
            hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            previewOnlyHintLabel = hint
            textColumn.addArrangedSubview(hint)
        }

        content.addArrangedSubview(glyphView)
        content.addArrangedSubview(textColumn)
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Space.md
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.lg),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.lg),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Space.sm),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.sm)
        ])

        isAccessibilityElement = true
        accessibilityLabel = item.accessibilityDescription(kindLabel: kind.label, excerpt: item.excerpt)
        if item.holdsOnlyPreview {
            // The control stays enabled so a tap reaches the handler, which explains why nothing
            // was inserted; VoiceOver reads the row as dimmed.
            accessibilityTraits = [.button, .notEnabled]
            accessibilityHint = "Too large to insert. Open Yank to copy it."
        } else {
            accessibilityTraits = .button
            accessibilityHint = "Inserts this clip"
        }

        applyAgePlacement()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (control: ClipRowControl, _) in
            control.layer.borderColor = UIColor(Color.yankHairline).cgColor
            control.applyAgePlacement()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A trait handler runs only on a later change, so the first placement happens in `init` with the
    /// default size and again here once the row knows its real text size.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyAgePlacement() }
    }

    /// Puts the age beside the excerpt, or under it at accessibility text sizes where the two
    /// would squeeze each other.
    private func applyAgePlacement() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        guard stacked != isAgeStacked else { return }
        isAgeStacked = stacked
        if stacked {
            textColumn.insertArrangedSubview(ageLabel, at: 1)
            ageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            content.addArrangedSubview(ageLabel)
            ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        }
    }

    private func rowTitle(for item: ClipboardItem, kind: ClipKind) -> String {
        if case let .link(url) = kind { return url.host ?? url.absoluteString }
        return item.excerpt
    }

    /// Briefly tints the hint line; an instant colour change, so Reduce Motion needs no special case.
    func flashPreviewOnlyHint(accent: UIColor) {
        guard let hint = previewOnlyHintLabel else { return }
        let restingColor = UIColor(Color.yankTextTertiary)
        hint.textColor = accent
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewOnlyFlashDuration) { [weak hint] in
            hint?.textColor = restingColor
        }
    }

    private static let previewOnlyFlashDuration: TimeInterval = 0.6

    func flashInserted(accent: UIColor) {
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.backgroundColor = accent.withAlphaComponent(0.22)
        } completion: { _ in
            UIView.animate(withDuration: 0.22, delay: 0.02, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.backgroundColor = self.restingColor
            }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if UIAccessibility.isReduceMotionEnabled {
                transform = .identity
                alpha = isHighlighted ? 0.9 : 1
                return
            }
            UIView.animate(withDuration: KeyboardMotion.pressDuration, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.99, y: 0.99) : .identity
                self.alpha = self.isHighlighted ? 0.9 : 1
            }
        }
    }
}
