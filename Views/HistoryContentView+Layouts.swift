import SwiftUI

// The scrolling stream (List / Grid / Masonry / Gallery) and the split rail + preview,
// plus the shared `selectable` cell wrapper that wires click / drag / accessibility.
extension HistoryContentView {
    // MARK: - Scrolling stream (List / Grid / Masonry / Gallery)

    var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredItems.isEmpty {
                    if !store.hasLoaded {
                        // Cold open of a large history: show a placeholder skeleton instead of
                        // the "clear" copy, so a populated clipboard never flashes a false empty.
                        HistoryLoadingState()
                            .padding(.horizontal, Space.lg)
                            .padding(.vertical, Space.md)
                    } else {
                        HistoryEmptyState(isClear: searchText.isEmpty && activeTagFilter == nil, settings: settings)
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                } else {
                    streamContent
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                }
            }
            .background(widthReader)
            .onChange(of: selectedIndex) { _, _ in
                guard scrollTrigger, let item = filteredItem(at: selectedIndex) else { return }
                if reduceMotion {
                    proxy.scrollTo(item.id, anchor: .center)
                } else {
                    withAnimation(YankMotion.state(reduceMotion)) { proxy.scrollTo(item.id, anchor: .center) }
                }
                scrollTrigger = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .yankWindowDidOpen)) { _ in
                scrollToOpeningPosition(using: proxy)
            }
            .onChange(of: viewMode) { _, _ in
                scrollToOpeningPosition(using: proxy)
            }
        }
    }

    func scrollToOpeningPosition(using proxy: ScrollViewProxy) {
        guard let id = HistoryOpeningPosition.scrollTargetID(in: filteredItems) else { return }
        proxy.scrollTo(id, anchor: .top)
    }

    @ViewBuilder
    var streamContent: some View {
        switch viewMode {
        case .list:    listLayout
        case .grid:    tileGrid(columns: [GridItem(.adaptive(minimum: density.tileMinWidth), spacing: density.spacing)])
        case .gallery: tileGrid(columns: [GridItem(.flexible(), spacing: density.spacing), GridItem(.flexible(), spacing: density.spacing)])
        case .masonry: masonryLayout
        case .split:   EmptyView()
        }
    }

    var listLayout: some View {
        let items = filteredItems
        let headers = ClipSectioning.headerLabels(items)
        return LazyVStack(alignment: .leading, spacing: density.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let label = headers[index] {
                    sectionHeaderView(label, isFirst: index == 0)
                }
                selectable(item, index) {
                    ClipboardItemRow(
                        item: item, store: store,
                        isPrimarySelection: item.id == selectedID,
                        isMultiSelected: selectedIDs.contains(item.id),
                        density: density,
                        quickIndex: index < 9 ? index + 1 : nil,
                        pastesOnClick: singleClickPastesInCurrentLayout,
                        onTagTap: rowTagFilterAction
                    )
                }
            }
        }
    }

    func tileGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: density.spacing) {
            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                selectable(item, index) { tile(item, index) }
            }
        }
    }

    var masonryLayout: some View {
        HStack(alignment: .top, spacing: density.spacing) {
            ForEach(0..<masonryColumns.count, id: \.self) { col in
                LazyVStack(spacing: density.spacing) {
                    ForEach(masonryColumns[col], id: \.element.id) { pair in
                        selectable(pair.element, pair.offset) { tile(pair.element, pair.offset) }
                    }
                }
            }
        }
        .onAppear { rebuildMasonryIfNeeded() }
    }

    /// Cheap signature of everything the masonry buckets depend on. Changing any field
    /// triggers a single rebuild; selection/hover re-renders (which leave these untouched)
    /// reuse the cached buckets.
    struct MasonryKey: Equatable {
        let token: Int
        let columns: Int
        let debouncedSearch: String
        let tag: String?
        let isMasonry: Bool
    }

    var masonryKey: MasonryKey {
        MasonryKey(
            token: store.changeToken,
            columns: max(2, tileColumnCount),
            debouncedSearch: searchTextDebounced,
            tag: activeTagFilter,
            isMasonry: viewMode == .masonry
        )
    }

    func rebuildMasonryIfNeeded() {
        guard viewMode == .masonry else { return }
        let columnCount = max(2, tileColumnCount)
        var buckets: [[(offset: Int, element: ClipboardItem)]] = Array(repeating: [], count: columnCount)
        for (offset, element) in filteredItems.enumerated() {
            buckets[offset % columnCount].append((offset, element))
        }
        masonryColumns = buckets
    }

    func tile(_ item: ClipboardItem, _ index: Int) -> some View {
        ClipTile(
            item: item, store: store, mode: viewMode, density: density,
            isPrimarySelection: item.id == selectedID,
            isMultiSelected: selectedIDs.contains(item.id),
            quickKey: index < 9 ? index + 1 : nil,
            pastesOnClick: singleClickPastesInCurrentLayout
        )
    }

    @ViewBuilder
    func selectable<Content: View>(_ item: ClipboardItem, _ index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .contentShape(Rectangle())
            // A keyboard-focus ring on the primary-selected cell — the list's keyboard
            // cursor, which is always live here (arrow keys navigate the stream throughout
            // the history window, even while the search field types). It's the system
            // 2pt focus colour, distinct from the accent selection *fill*, so arrow-key
            // users get one unambiguous "you are here" that doesn't rely on hue alone
            // (WCAG 2.4.7 / 1.4.1). It dims while the search field is actively being typed
            // into, so the field's own caret-focus ring never has to compete with it.
            .overlay {
                if item.id == selectedID {
                    // Match the cell's own corner so the ring stays concentric: tiles round
                    // at Radius.md, rows/split at the shared clipRowCornerRadius.
                    RoundedRectangle(cornerRadius: viewMode.isTiled ? Radius.md : clipRowCornerRadius)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor),
                                      lineWidth: 2)
                        // Still clearly present while the search field types — it eases back,
                        // it doesn't disappear, so the keyboard cursor never goes ambiguous.
                        .opacity(listHasKeyboardFocus ? 1 : 0.7)
                        .accessibilityHidden(true)
                }
            }
            .overlay(
                ClickDetector { modifiers, clickCount in
                    selectedIndex = index
                    let action = ClipClickPolicy.action(
                        for: ClipClickModifiers(
                            hasCommand: modifiers.hasCommand,
                            hasShift: modifiers.hasShift
                        ),
                        clickCount: clickCount,
                        singleClickPastes: singleClickPastesInCurrentLayout
                    )
                    switch action {
                    case .paste:
                        selectSingle(item.id)
                        pasteWithPulse(item)
                    case .selectSingle:
                        selectSingle(item.id)
                    case .toggleSelection:
                        toggleSelection(item.id)
                    case .extendSelection:
                        extendSelectionTo(item.id)
                    }
                }
            )
            .scaleEffect(pulseID == item.id ? YankMotion.pasteScale : 1.0)
            .offset(y: pulseID == item.id ? YankMotion.pasteLift : 0)
            .zIndex(pulseID == item.id ? 1 : 0)
            .matchedGeometryEffect(id: item.id, in: cardNS)
            .id(item.id)
            // Drag a clip straight into another app or Finder — the defining power-user
            // gesture of a clipboard manager. The provider derives text / URL / image
            // representations from the clip's kind; the preview reuses the tile so the
            // drag image matches what's on screen.
            .onDrag({ dragProvider(for: item) }, preview: { dragPreview(for: item) })
            .animation(YankMotion.quick(reduceMotion), value: listHasKeyboardFocus)
            // The cells are driven by a mouse-tracking overlay + the global key
            // monitor, neither of which assistive tech can see. Expose each as one
            // button: a clean spoken label, paste as the default action, and an
            // explicit Select for inspecting without pasting.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                item.accessibilityDescription(kindLabel: item.kind.label, excerpt: item.excerpt)
            )
            .accessibilityAddTraits(item.id == selectedID ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Pastes this clip")
            .accessibilityAction {
                selectedIndex = index
                pasteWithPulse(item)
            }
            .accessibilityAction(named: "Select") {
                selectedIndex = index
                selectSingle(item.id)
            }
            // The drag-out is pointer-only, so give assistive tech a parallel route to the
            // same outcome — put the clip on the pasteboard without pasting it anywhere.
            .accessibilityAction(named: "Copy") {
                onCopyToClipboard(item)
            }
            // Pin / bookmark / delete are otherwise hotkey-only (the global key monitor acts
            // on the selected clip), invisible to VoiceOver. Expose them per-cell so an
            // assistive-tech user has the same actions the pointer and keyboard do.
            .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") {
                store.togglePin(for: item)
            }
            .accessibilityAction(named: item.isBookmarked ? "Remove Bookmark" : "Bookmark") {
                store.toggleBookmark(for: item)
            }
            .accessibilityAction(named: "Delete") {
                deleteClipWithUndo(item)
            }
    }

    /// True when the search field isn't actively focused, so the stream's keyboard-cursor
    /// ring can show at full strength. Arrow keys are routed throughout the history window
    /// regardless, but the only place AppKit draws its own focus ring is the search field —
    /// so the cursor ring dims (rather than competes) while the field is being typed into.
    var listHasKeyboardFocus: Bool { !isSearchFocused }

    /// A subtle drag image reusing the tile, so what lifts off the stream reads as the
    /// same clip. Width-bounded so a long row doesn't drag an oversized ghost.
    func dragPreview(for item: ClipboardItem) -> some View {
        ClipTile(
            item: item, store: store, mode: .grid, density: density,
            isPrimarySelection: false, isMultiSelected: false
        )
        .frame(width: density.tileMinWidth)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    func sectionHeaderView(_ label: String, isFirst: Bool) -> some View {
        Text(label)
            .font(.system(size: TypeScale.micro, weight: .semibold).smallCaps())
            .foregroundColor(.yankTextTertiary)
            .padding(.horizontal, Space.md)
            .padding(.top, isFirst ? 0 : Space.lg)
            .padding(.bottom, Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { streamWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newValue in streamWidth = newValue }
        }
    }

    // MARK: - Split mode (rail + live preview)

    var splitLayout: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if filteredItems.isEmpty, !store.hasLoaded {
                        HistoryLoadingState()
                            .padding(Space.sm)
                    } else {
                        LazyVStack(alignment: .leading, spacing: density.spacing) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                selectable(item, index) {
                                    ClipboardItemRow(
                                        item: item, store: store,
                                        isPrimarySelection: item.id == selectedID,
                                        isMultiSelected: selectedIDs.contains(item.id),
                                        density: .snug,
                                        quickIndex: index < 9 ? index + 1 : nil,
                                        pastesOnClick: singleClickPastesInCurrentLayout,
                                        onTagTap: rowTagFilterAction
                                    )
                                }
                            }
                        }
                        .padding(Space.sm)
                    }
                }
                .onChange(of: selectedIndex) { _, _ in
                    guard let item = filteredItem(at: selectedIndex) else { return }
                    if reduceMotion {
                        proxy.scrollTo(item.id, anchor: .center)
                    } else {
                        withAnimation(YankMotion.state(reduceMotion)) { proxy.scrollTo(item.id, anchor: .center) }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .yankWindowDidOpen)) { _ in
                    scrollToOpeningPosition(using: proxy)
                }
            }
            .frame(width: splitRailWidth)

            Rectangle().fill(Color.yankHairline).frame(width: Hairline.width)

            Group {
                if selectedItem != nil {
                    ClipDetailView(
                        store: store, selectedItems: selectedItems, model: detail,
                        onCopy: onCopyToClipboard, onDownloadImages: downloadAllImages,
                        onDelete: deleteClipWithUndo
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                } else if !store.hasLoaded {
                    HistoryLoadingState()
                        .padding(Space.lg)
                        .transition(.opacity)
                } else {
                    HistoryEmptyState(isClear: searchText.isEmpty && activeTagFilter == nil, settings: settings)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Tiles per row for the current mode/width — the single source of truth shared by
    /// the masonry layout and the up/down row jumps.
    var tileColumnCount: Int {
        HistoryLayout.tileColumnCount(viewMode: viewMode, streamWidth: streamWidth, density: density)
    }
}
