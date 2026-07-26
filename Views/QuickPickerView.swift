import SwiftUI
import Cocoa
import Observation

@MainActor
@Observable
final class QuickPickerSmartSearchState {
    typealias Search = @MainActor @Sendable (String) async -> [ClipboardItem]

    private(set) var results: [ClipboardItem]?
    private(set) var isInterpreting = false
    private(set) var resultRevision = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    var hasOwnedTask: Bool { task != nil }

    func interpret(_ phrase: String, using search: @escaping Search) {
        guard !phrase.isEmpty else {
            queryDidChange()
            return
        }

        invalidateOwnedRequest()
        let requestID = UUID()
        self.requestID = requestID
        isInterpreting = true

        let task = Task { @MainActor [weak self, search] in
            let results = await search(phrase)
            guard let self,
                  !Task.isCancelled,
                  self.requestID == requestID else {
                return
            }
            self.task = nil
            self.requestID = nil
            self.results = results
            self.isInterpreting = false
            self.resultRevision &+= 1
        }
        self.task = task
    }

    func queryDidChange() {
        invalidateOwnedRequest()
        results = nil
    }

    func disappear() {
        invalidateOwnedRequest()
    }

    private func invalidateOwnedRequest() {
        task?.cancel()
        task = nil
        requestID = nil
        isInterpreting = false
    }
}

struct QuickPickerView: View {
    let store: ClipboardStore
    @Bindable var presentationState: QuickPickerPresentationState
    let onPaste: (ClipboardItem) -> Void
    let onPasteAsText: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onSmartPaste: (ClipboardItem, TextTransform) -> Void
    let onDismiss: () -> Void
    let onOpenFullHistory: () -> Void
    let onStartPasteSequence: () -> Void
    let onSmartSearch: QuickPickerSmartSearchState.Search

    @State private var searchText = ""
    @State private var selection = ClipSelectionState()
    @State private var smartSearchState = QuickPickerSmartSearchState()
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [ClipboardItem] {
        smartSearchState.results ?? store.filteredItems(search: searchText, activeTag: nil)
    }

    private var selectedItem: ClipboardItem? {
        guard let id = selection.focusedID else { return nil }
        return items.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            YankWindowBackground()

            VStack(spacing: 0) {
                header
                Divider().overlay(Color.yankHairline)
                list
                footer
            }
        }
        .frame(width: 392, height: 430)
        .tint(AppTheme.active.foreground)
        .background(keyMonitor.frame(width: 0, height: 0))
        .onAppear {
            reconcileSelection(preferFirst: true)
            requestSearchFocus(for: presentationState.searchFocusRequest)
        }
        .onChange(of: presentationState.searchFocusRequest) { _, request in
            requestSearchFocus(for: request)
        }
        .onChange(of: searchText) { _, _ in
            smartSearchState.queryDidChange()
            reconcileSelection(preferFirst: true)
        }
        .onChange(of: store.changeToken) { _, _ in reconcileSelection(preferFirst: false) }
        .onChange(of: smartSearchState.resultRevision) { _, _ in
            reconcileSelection(preferFirst: true)
        }
        .onDisappear {
            smartSearchState.disappear()
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: TypeScale.control, weight: .medium))
                    .foregroundColor(.yankTextTertiary)
                    .accessibilityHidden(true)

                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: TypeScale.body))
                    .focused($searchFocused)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(Color.yankRaised.opacity(0.65), in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(searchFocused ? AppTheme.active.foreground.opacity(0.45) : Color.yankHairline,
                                  lineWidth: searchFocused ? 1.25 : Hairline.width)
            )

            if FoundationModelEnricher.isAvailable {
                if smartSearchState.isInterpreting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: ControlTarget.compact, height: ControlTarget.compact)
                        .accessibilityLabel("Interpreting search")
                } else {
                    PickerIconButton(systemName: "text.magnifyingglass",
                                     label: "Interpret search",
                                     action: interpretSearch)
                }
            }
            PickerIconButton(systemName: "list.number",
                             label: "Start Paste Sequence",
                             action: onStartPasteSequence)
            PickerIconButton(systemName: "arrow.up.left.and.arrow.down.right",
                             label: "Full history",
                             action: onOpenFullHistory)
            PickerIconButton(systemName: "xmark",
                             label: "Close",
                             action: onDismiss)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.md)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: Space.xs) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                selection.selectSingle(item.id, in: items)
                                onPaste(item)
                            } label: {
                                QuickPickerRow(
                                    item: item,
                                    store: store,
                                    isSelected: item.id == selection.focusedID,
                                    quickIndex: index < 9 ? index + 1 : nil
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { rowMenu(for: item) }
                            .accessibilityLabel(
                                item.accessibilityDescription(kindLabel: item.kind.label, excerpt: item.excerpt)
                            )
                            .accessibilityAddTraits(item.id == selection.focusedID ? .isSelected : [])
                            .accessibilityHint("Pastes this clip")
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                }
            }
            .onChange(of: selection.focusedID) { _, id in
                guard let id else { return }
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(YankMotion.quick(false)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: IconSize.emptyState, weight: .medium))
                .foregroundColor(.yankTextTertiary)
            Text(searchText.isEmpty ? "No clips" : "No matches")
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Text(
                smartSearchState.results != nil
                    ? "Smart results · \(items.count)"
                    : "\(items.count) \(items.count == 1 ? "clip" : "clips")"
            )
                .font(.system(size: TypeScale.micro))
                .foregroundColor(.yankTextTertiary)
            Spacer()
            if let selectedItem {
                ClipStatusBadge(item: selectedItem)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Color.yankRaised.opacity(0.78))
    }

    private var keyMonitor: some View {
        QuickPickerKeyMonitor(handlers: QuickPickerKeyMonitor.Handlers(
            onUp: { moveSelection(by: -1) },
            onDown: { moveSelection(by: 1) },
            onEnter: { pasteSelected() },
            onCopy: { copySelected() },
            onPasteAsText: { pasteSelectedAsText() },
            onEscape: onDismiss,
            onOpenFullHistory: onOpenFullHistory,
            onFocusSearch: { searchFocused = true },
            onPasteIndex: { pasteItem(atQuickIndex: $0) }
        ))
    }

    private func interpretSearch() {
        let phrase = searchText
        guard !phrase.isEmpty, !smartSearchState.isInterpreting else { return }
        smartSearchState.interpret(phrase, using: onSmartSearch)
    }

    private func requestSearchFocus(for request: Int) {
        searchFocused = false
        Task { @MainActor in
            await Task.yield()
            guard presentationState.searchFocusRequest == request else { return }
            searchFocused = true
        }
    }

    @ViewBuilder
    private func rowMenu(for item: ClipboardItem) -> some View {
        Button("Paste") { onPaste(item) }
        Button("Copy") { onCopy(item) }
        ForEach(item.aiTags.filter { !item.tags.contains($0) }, id: \.self) { tag in
            Button("Add “\(tag)” Tag") { store.addTag(tag, to: item) }
        }
        if item.type == .text, FoundationModelEnricher.isAvailable {
            Menu("Smart Paste") {
                ForEach(TextTransform.allCases) { transform in
                    Button {
                        onSmartPaste(item, transform)
                    } label: {
                        Label(transform.label, systemImage: transform.symbol)
                    }
                }
            }
        }
    }

    private func reconcileSelection(preferFirst: Bool) {
        if preferFirst {
            selection.selectDefault(in: items)
            return
        }
        selection.reconcile(with: items)
        if selection.focusedID == nil {
            selection.selectDefault(in: items)
        }
    }

    private func moveSelection(by delta: Int) {
        selection.move(by: delta, in: items)
    }

    private func pasteSelected() {
        guard let selectedItem else { return }
        onPaste(selectedItem)
    }

    private func copySelected() {
        guard let selectedItem else { return }
        onCopy(selectedItem)
    }

    private func pasteSelectedAsText() {
        guard let selectedItem else { return }
        onPasteAsText(selectedItem)
    }

    private func pasteItem(atQuickIndex index: Int) {
        let itemIndex = index - 1
        guard items.indices.contains(itemIndex) else { return }
        onPaste(items[itemIndex])
    }
}

private struct QuickPickerRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let isSelected: Bool
    let quickIndex: Int?

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipKind { item.kind }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            icon
                .frame(width: IconSize.clipRow, height: IconSize.clipRow)

            VStack(alignment: .leading, spacing: Space.xxs) {
                primaryText

                HStack(spacing: Space.xs) {
                    if let detail = kind.secondaryDetail(sourceApp: item.sourceApp) {
                        Text(detail)
                            .lineLimit(1)
                            .truncationMode(kind.isLink ? .middle : .tail)
                    }
                    Text(item.relativeAge)
                }
                .font(.system(size: TypeScale.micro))
                .foregroundColor(.yankTextTertiary)

                let suggested = item.aiTags.filter { !item.tags.contains($0) }.prefix(2)
                if !suggested.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(Array(suggested), id: \.self) { tag in
                            AITagChip(label: tag)
                        }
                    }
                }
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: Space.xs) {
                if let quickIndex {
                    QuickKeyBadge(key: quickIndex)
                }
                ClipStatusBadge(item: item)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(rowBorder, lineWidth: isSelected ? 1.5 : Hairline.width)
        )
        .onHover { isHovered = $0 }
        .animation(YankMotion.quick(reduceMotion), value: isHovered)
        .animation(YankMotion.state(reduceMotion), value: isSelected)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(AppTheme.active.selectionFill)
        } else if isHovered {
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Color.yankHover)
        }
    }

    private var rowBorder: Color {
        if isSelected { return AppTheme.active.foreground.opacity(0.45) }
        if isHovered { return Color.yankHairline }
        return Color.clear
    }

    @ViewBuilder
    private var primaryText: some View {
        if case let .link(url) = kind {
            Text(url.host ?? url.absoluteString)
                .font(.system(size: TypeScale.body, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        } else {
            Text(item.excerpt)
                .font(.system(size: TypeScale.body, design: kindTextDesign))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
    }

    private var kindTextDesign: Font.Design {
        if case .code = kind { return .monospaced }
        return .default
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case let .color(color, _):
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .stroke(Color.yankSubtleBorder, lineWidth: Hairline.width)
                )
        case .image:
            ClipThumbnail(item: item, store: store, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        default:
            ClipKindIcon(glyph: kind.glyph)
        }
    }
}

private struct PickerIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: TypeScale.control, weight: .medium))
                .frame(width: ControlTarget.compact, height: ControlTarget.compact)
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovered ? AppTheme.active.foreground : .yankTextTertiary)
        .background(isHovered ? Color.yankHover : Color.clear, in: RoundedRectangle(cornerRadius: Radius.sm))
        .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
        .onHover { isHovered = $0 }
        .animation(YankMotion.quick(reduceMotion), value: isHovered)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct QuickPickerKeyMonitor: NSViewRepresentable {
    struct Handlers {
        let onUp: () -> Void
        let onDown: () -> Void
        let onEnter: () -> Void
        let onCopy: () -> Void
        let onPasteAsText: () -> Void
        let onEscape: () -> Void
        let onOpenFullHistory: () -> Void
        let onFocusSearch: () -> Void
        let onPasteIndex: (Int) -> Void
    }

    let handlers: Handlers

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard WindowKeyEventScope.shouldHandle(
                monitoredWindow: view?.window,
                keyWindow: NSApp.keyWindow
            ) else { return event }
            switch event.keyCode {
            case 126:
                handlers.onUp()
                return nil
            case 125:
                handlers.onDown()
                return nil
            case 36:
                if event.modifierFlags.contains(.option) {
                    handlers.onPasteAsText()
                } else if event.modifierFlags.contains(.command) {
                    handlers.onCopy()
                } else {
                    handlers.onEnter()
                }
                return nil
            case 53:
                handlers.onEscape()
                return nil
            case 3:
                if event.modifierFlags.contains(.command) {
                    handlers.onFocusSearch()
                    return nil
                }
                return event
            case 31:
                if event.modifierFlags.contains(.command) {
                    handlers.onOpenFullHistory()
                    return nil
                }
                return event
            case 18, 19, 20, 21, 22, 23, 25, 26, 28:
                if event.modifierFlags.contains(.command),
                   let index = Self.quickIndex(for: event.keyCode) {
                    handlers.onPasteIndex(index)
                    return nil
                }
                return event
            default:
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func quickIndex(for keyCode: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }

    final class Coordinator {
        var monitor: Any?

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}
