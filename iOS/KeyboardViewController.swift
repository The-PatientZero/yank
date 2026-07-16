import SwiftUI
import UIKit
import os

private enum KeyboardMotion {
    static let pressDuration: TimeInterval = 0.14
}

final class KeyboardViewController: UIInputViewController {
    private static let log = Logger(subsystem: "com.thepatientzero.yank", category: "keyboard")
    private let appGroup = AppGroupContainer.live()
    private var items: [ClipboardItem] = []

    private let maxVisibleClips = 10
    private let maxSearchResults = 25

    private static var minKeyboardHeight: CGFloat { UIFontMetrics.default.scaledValue(for: 180) }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var statusHost: UIHostingController<KeyboardStatusView>?
    private var searchField: UITextField?
    private var searchQuery = ""
    private let resultsStack = UIStackView()

    private enum Metrics {
        static let rowCornerRadius = Radius.md
    }

    private var rowBackground: UIColor { UIColor(Color.yankRaised) }
    private var rowBorder: UIColor { UIColor(Color.yankHairline) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Color.yankSurface)
        configureLayout()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scrollView.flashScrollIndicators()
        render()
    }

    // MARK: - Layout scaffold

    private func configureLayout() {
        let heightConstraint = view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minKeyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

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

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    // MARK: - State machine

    private func render() {
        teardownStatusCard()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        searchField = nil

        guard reloadHistory() else {
            presentStatusCard(.storageError)
            return
        }

        let hasInsertableClips = !KeyboardClipSearch.insertableItems(from: items).isEmpty
        if !hasInsertableClips {
            presentStatusCard(.empty)
            return
        }

        stack.addArrangedSubview(buildSearchField())
        stack.addArrangedSubview(resultsStack)
        updateSearchResults()

        if needsInputModeSwitchKey {
            stack.addArrangedSubview(switchButton())
        }
    }

    private func updateSearchResults() {
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let filtered = KeyboardClipSearch.results(
            from: items,
            query: searchQuery,
            emptyLimit: maxVisibleClips,
            searchLimit: maxSearchResults
        )

        if filtered.isEmpty {
            let noResultsLabel = UILabel()
            noResultsLabel.text = "No matching clips"
            noResultsLabel.font = .preferredFont(forTextStyle: .footnote)
            noResultsLabel.textColor = UIColor(Color.yankTextTertiary)
            noResultsLabel.textAlignment = .center
            noResultsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true
            resultsStack.addArrangedSubview(noResultsLabel)
        } else {
            for item in filtered {
                resultsStack.addArrangedSubview(clipRow(for: item))
            }
        }
    }

    /// The keyboard is intentionally a read-only App Group consumer. It reads only the
    /// host's bounded projection without creating directories or scanning pending payloads.
    private func reloadHistory() -> Bool {
        guard let appGroup else {
            items = []
            Self.log.error("App Group container is unavailable; keyboard history cannot be read.")
            return false
        }
        do {
            items = try KeyboardHistoryReader(projectionURL: appGroup.keyboardProjectionURL).load()
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
        if needsInputModeSwitchKey {
            stack.addArrangedSubview(switchButton())
        }
    }

    private func teardownStatusCard() {
        guard let host = statusHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        statusHost = nil
    }

    // MARK: - Search field

    private func buildSearchField() -> UIView {
        let field = UITextField()
        field.placeholder = "Search clips…"
        field.text = searchQuery
        field.font = .preferredFont(forTextStyle: .callout)
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(Color.yankRaised)
        container.layer.cornerRadius = Radius.md
        container.layer.borderColor = UIColor(Color.yankHairline).cgColor
        container.layer.borderWidth = Hairline.width
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak container] (_: KeyboardViewController, _) in
            container?.layer.borderColor = UIColor(Color.yankHairline).cgColor
        }

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.tintColor = .secondaryLabel
        searchIcon.contentMode = .scaleAspectFit
        searchIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .callout)
        searchIcon.isAccessibilityElement = false
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchIcon)
        container.addSubview(field)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Space.md),
            searchIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: Space.sm),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Space.md),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: Space.sm),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Space.sm)
        ])
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true

        field.addAction(UIAction { [weak self, weak field] _ in
            guard let self else { return }
            let nextQuery = field?.text ?? ""
            guard nextQuery != self.searchQuery else { return }
            self.searchQuery = nextQuery
            self.updateSearchResults()
        }, for: .editingChanged)

        field.accessibilityLabel = "Search clips"

        searchField = field
        return container
    }

    // MARK: - Clip row

    private func clipRow(for item: ClipboardItem) -> UIControl {
        let row = ClipRowControl(item: item, background: rowBackground, border: rowBorder)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: ControlTarget.touch).isActive = true
        row.addAction(UIAction { [weak self, weak row] _ in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            row?.flashInserted(accent: self.view.tintColor)
            self.textDocumentProxy.insertText(item.textContent ?? "")
        }, for: .touchUpInside)
        return row
    }

    private func switchButton() -> UIButton {
        let button = UIButton(type: .system)
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
        button.addAction(UIAction { [weak self] _ in
            self?.advanceToNextInputMode()
        }, for: .touchUpInside)
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

private final class ClipRowControl: UIControl {
    private let restingColor: UIColor
    private let glyphView = UIImageView()
    private let excerptLabel = UILabel()
    private let ageLabel = UILabel()

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

        let content = UIStackView(arrangedSubviews: [glyphView, excerptLabel, ageLabel])
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
        accessibilityTraits = .button
        accessibilityLabel = item.excerpt
        accessibilityValue = item.relativeAge
        accessibilityHint = "Inserts this clip"

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (control: ClipRowControl, _) in
            control.layer.borderColor = UIColor(Color.yankHairline).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rowTitle(for item: ClipboardItem, kind: ClipKind) -> String {
        if case let .link(url) = kind { return url.host ?? url.absoluteString }
        return item.excerpt
    }

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
