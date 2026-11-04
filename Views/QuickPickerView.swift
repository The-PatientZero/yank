import SwiftUI
import Cocoa
import Observation

struct QuickPickerView: View {
    let store: ClipboardStore
    let settings: SettingsManager
    @Bindable var presentationState: QuickPickerPresentationState
    let onPaste: (ClipboardItem) -> Void
    let onPasteAsText: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onSmartPaste: (ClipboardItem, TextTransform) -> Void
    let onDismiss: () -> Void
    let onOpenFullHistory: () -> Void
    let onStartPasteSequence: () -> Void
    let onResumeCapture: () -> Void
    let onSmartSearch: QuickPickerSmartSearchState.Search

    @State private var searchText = ""
    /// The query the list is filtered by: `searchText` once typing has paused.
    @State private var debouncedQuery = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var selection = ClipSelectionState()
    @State private var smartSearchState = QuickPickerSmartSearchState()
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [ClipboardItem] {
        smartSearchState.results ?? store.filteredItems(search: debouncedQuery, activeTag: nil)
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
        .frame(width: QuickPickerLayout.size.width, height: QuickPickerLayout.size.height)
        .tint(AppTheme.active.foreground)
        .background(keyMonitor.frame(width: 0, height: 0))
        .onAppear {
            reconcileSelection(preferFirst: true)
            requestSearchFocus(for: presentationState.searchFocusRequest)
        }
        .onChange(of: presentationState.searchFocusRequest) { _, request in
            requestSearchFocus(for: request)
        }
        .onChange(of: searchText) { _, newValue in
            smartSearchState.queryDidChange()
            scheduleSearch(for: newValue)
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
                                  lineWidth: searchFocused ? Stroke.focusRing : Hairline.width)
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
                scroll(to: id, with: proxy)
            }
            .onChange(of: presentationState.openRequest) { _, _ in
                resetForOpen(scrollingWith: proxy)
            }
        }
    }

    private func scroll(to id: UUID, with proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(YankMotion.quick(false)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// Starts every open from the same place: empty search, newest unpinned clip selected and in view.
    private func resetForOpen(scrollingWith proxy: ScrollViewProxy) {
        searchText = ""
        searchDebounceTask?.cancel()
        debouncedQuery = ""
        smartSearchState.queryDidChange()
        selection.selectDefault(in: items)
        guard let id = HistoryOpeningPosition.selectionID(in: items) else { return }
        // The list is rebuilt for the cleared search; scroll once that pass has run.
        Task { @MainActor in
            scroll(to: id, with: proxy)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: debouncedQuery.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: IconSize.emptyState, weight: .medium))
                .foregroundColor(.yankTextTertiary)
            Text(debouncedQuery.isEmpty ? "No clips" : "No matches")
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
                .lineLimit(1)
                .layoutPriority(1)
            if settings.capturePaused {
                pausedNotice
            }
            Spacer()
            if let selectedItem {
                ClipStatusBadge(item: selectedItem)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Color.yankRaised.opacity(0.78))
    }

    /// The saved pause and the way to end it. It keeps its layout priority, so the selected
    /// clip's badge gives way first at the picker's width.
    private var pausedNotice: some View {
        HStack(spacing: Space.sm) {
            Text("Capture paused")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Button("Resume", action: onResumeCapture)
                .buttonStyle(.plain)
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .accessibilityLabel("Resume capture")
                .accessibilityHint("Starts saving copied items to history again.")
        }
        .layoutPriority(1)
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

    /// Filters at once for an empty or `#` query, otherwise after typing pauses; a newer keystroke
    /// cancels the pending filter.
    private func scheduleSearch(for text: String) {
        searchDebounceTask?.cancel()
        if ClipQuery.appliesWithoutDebounce(text) {
            debouncedQuery = text
            reconcileSelection(preferFirst: true)
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: ClipQuery.searchDebounce)
            guard !Task.isCancelled else { return }
            debouncedQuery = text
            reconcileSelection(preferFirst: true)
        }
    }

    /// Return, the arrow keys, copy and paste act on the list for the text typed so far, never on
    /// the previous result list: any pending filter is applied before the selection is read.
    private func applyPendingSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        guard debouncedQuery != searchText else { return }
        debouncedQuery = searchText
        reconcileSelection(preferFirst: true)
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
}

private extension QuickPickerView {
    private func moveSelection(by delta: Int) {
        applyPendingSearch()
        selection.move(by: delta, in: items)
    }

    private func pasteSelected() {
        applyPendingSearch()
        guard let selectedItem else { return }
        onPaste(selectedItem)
    }

    private func copySelected() {
        applyPendingSearch()
        guard let selectedItem else { return }
        onCopy(selectedItem)
    }

    private func pasteSelectedAsText() {
        applyPendingSearch()
        guard let selectedItem else { return }
        onPasteAsText(selectedItem)
    }

    private func pasteItem(atQuickIndex index: Int) {
        applyPendingSearch()
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
                .foregroundColor(isSelected ? .yankTextTertiarySelected : .yankTextTertiary)

                let suggested = item.aiTags.filter { !item.tags.contains($0) }.prefix(2)
                if !suggested.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(Array(suggested), id: \.self) { tag in
                            AITagChip(label: tag, onSelection: isSelected)
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
                .strokeBorder(rowBorder, lineWidth: isSelected ? Stroke.focusRing : Hairline.width)
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
            QuickPickerThumbnailFrame {
                ClipThumbnail(item: item, store: store, contentMode: .fill)
            }
        default:
            ClipKindIcon(glyph: kind.glyph)
        }
    }
}
