import SwiftUI

struct HistoryView: View {
    var store: ClipStore
    var settings: IOSSettings
    var iCloudSignedOut: Bool = false
    var onRetrySync: (() async -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var activeTag: String?
    @State private var showSettings = false

    @State private var openItem: ClipboardItem?

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    @State private var successPulse = 0
    @State private var warningPulse = 0

    @State private var copiedItemID: UUID?

    @State private var commitTask: Task<Void, Never>?

    @ScaledMetric(relativeTo: .title2) var wordmarkSize: CGFloat = TypeScale.stat

    private var filtered: [ClipboardItem] {
        store.filteredItems(search: query, activeTag: activeTag)
    }

    private var visibleItems: [ClipboardItem] {
        PendingDeletePolicy.visibleItems(store.items, pending: store.pendingDeletion)
    }

    private var displayedTags: [String] { TagSuggestions.matching(searchText: query, in: store.allTags) }

    private var selectedItems: [ClipboardItem] { filtered.filter { selection.contains($0.id) } }
    private var allSelected: Bool { !filtered.isEmpty && filtered.allSatisfy { selection.contains($0.id) } }
    private var selectedAllPinned: Bool { !selectedItems.isEmpty && selectedItems.allSatisfy(\.isPinned) }
    private var selectedAllBookmarked: Bool { !selectedItems.isEmpty && selectedItems.allSatisfy(\.isBookmarked) }
    private var showsTagBar: Bool { !isSelecting && !store.allTags.isEmpty }

    private func isOpen(_ item: ClipboardItem) -> Bool {
        sizeClass == .regular && openItem?.id == item.id
    }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                browse.navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 480)
            } detail: {
                NavigationStack { detailColumn }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                browse.navigationDestination(item: $openItem) { item in
                    ClipDetailView(item: item, store: store)
                }
            }
        }
    }

    private var isAwaitingFirstSync: Bool {
        store.items.isEmpty && store.firstSyncState == .syncing
    }

    private var firstSyncFailureMessage: String? {
        guard store.items.isEmpty else { return nil }
        return store.firstSyncState.failureMessage
    }

    private var browse: some View {
        Group {
            if store.items.isEmpty {
                if iCloudSignedOut {
                    iCloudSignedOutState
                } else if let firstSyncFailureMessage {
                    syncFailedState(message: firstSyncFailureMessage)
                } else if isAwaitingFirstSync {
                    syncingState
                } else {
                    onboardingState
                }
            } else {
                content
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.storageUnavailable {
                StorageUnavailableBanner()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let pending = store.pendingDeletion {
                UndoDeleteBanner(message: undoMessage(count: pending.items.count)) {
                    performUndo()
                } onDismiss: {
                    commitDelete()
                }
            }
        }
        .animation(IOSMotion.state(reduceMotion), value: isAwaitingFirstSync)
        .animation(IOSMotion.state(reduceMotion), value: firstSyncFailureMessage)
        .animation(IOSMotion.state(reduceMotion), value: store.storageUnavailable)
        .animation(IOSMotion.state(reduceMotion), value: store.pendingDeletion != nil)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(HistorySearchModifier(query: $query, isEnabled: !store.items.isEmpty))
        .onSubmit(of: .search) { applyTagSuggestion() }
        .toolbar { toolbarContent }
        .animation(IOSMotion.state(reduceMotion), value: isSelecting)
        .animation(IOSMotion.state(reduceMotion), value: activeTag)
        .animation(IOSMotion.state(reduceMotion), value: openItem?.id)
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store, settings: settings)
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .sensoryFeedback(.success, trigger: successPulse)
        .sensoryFeedback(.warning, trigger: warningPulse)
        .onChange(of: store.pendingDeletion != nil) { _, isPending in
            armCommitTimer(isPending)
        }
    }

    // MARK: - iPad detail column

    @ViewBuilder private var detailColumn: some View {
        if let item = openItem, visibleItems.contains(where: { $0.id == item.id }) {
            ClipDetailView(item: item, store: store)
        } else {
            detailPlaceholder
        }
    }

    private var detailPlaceholder: some View {
        EmptyStateView(animatesIn: false) {
            Text("Select a clip").font(.yank(.title3, weight: .semibold))
            Text("Pick a clip to preview, copy, or tag it.")
                .font(.yank(.subheadline))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { exitSelection() }
            }
            ToolbarItem(placement: .principal) {
                Text(selection.isEmpty ? "Select Clips" : "\(selection.count) Selected")
                    .font(.yank(.headline))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "Deselect All" : "Select All") { toggleSelectAll() }
            }
            ToolbarItemGroup(placement: .bottomBar) { selectionActions }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .principal) { YankWordmark(size: wordmarkSize) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { enterSelection() }
            }
        }
    }

    @ViewBuilder private var selectionActions: some View {
        Button { applyPin() } label: {
            Label(selectedAllPinned ? "Unpin" : "Pin", systemImage: selectedAllPinned ? "pin.slash" : "pin")
        }.disabled(selection.isEmpty)
        Spacer()
        Button { applyBookmark() } label: {
            Label(selectedAllBookmarked ? "Remove Bookmark" : "Bookmark",
                  systemImage: selectedAllBookmarked ? "bookmark.slash" : "bookmark")
        }.disabled(selection.isEmpty)
        Spacer()
        Button { shareSelection() } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }.disabled(selection.isEmpty)
        Spacer()
        Button(role: .destructive) { deleteSelection() } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(selection.isEmpty)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            if syncPaused {
                syncPausedStrip
                    .transition(tagBarTransition)
                Divider()
            }
            if showsTagBar {
                tagFilterBar
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                    .transition(tagBarTransition)
                Divider()
            }
            if filtered.isEmpty {
                if store.pendingDeletion != nil && visibleItems.isEmpty {
                    pendingDeleteState
                } else {
                    noMatchesState
                }
            } else {
                switch settings.viewMode {
                case .grid, .masonry, .gallery: tiles.transition(contentTransition)
                default:                        list.transition(contentTransition)
                }
            }
        }
        .animation(IOSMotion.state(reduceMotion), value: syncPaused)
        .animation(IOSMotion.state(reduceMotion), value: showsTagBar)
        .animation(IOSMotion.state(reduceMotion), value: settings.viewMode)
        .animation(IOSMotion.state(reduceMotion), value: settings.density)
    }

    private var syncPaused: Bool {
        if case .failed = store.syncStatus { return !store.items.isEmpty }
        return false
    }

    private var syncPausedStrip: some View {
        HStack(spacing: Space.md) {
            Label("Sync paused", systemImage: "exclamationmark.icloud")
                .font(.yank(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let onRetrySync {
                Button("Retry") {
                    Task { await onRetrySync() }
                }
                .font(.yank(.caption, weight: .semibold))
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yankDanger.opacity(0.08))
    }

    private var tagBarTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

    private var gridColumns: [GridItem] {
        let spacing = settings.density.spacing
        if settings.viewMode == .gallery {
            return [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
        }
        return [GridItem(.adaptive(minimum: settings.density.tileMinWidth), spacing: spacing)]
    }

    private var tiles: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: settings.density.spacing) {
                ForEach(filtered) { item in tileCell(item) }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .background(Color.yankSurface)
        .refreshable { await onRetrySync?() }
    }

    @ViewBuilder private func tileCell(_ item: ClipboardItem) -> some View {
        let tile = ClipTileView(
            item: item,
            store: store,
            mode: settings.viewMode,
            density: settings.density,
            isHighlighted: isOpen(item),
            isSelected: selection.contains(item.id)
        )
        if isSelecting {
            Button { toggle(item.id) } label: {
                tile
                    .overlay(alignment: .topTrailing) {
                        selectionMark(item.id)
                            .background(Circle().fill(.ultraThinMaterial).padding(Space.md))
                            .padding(Space.xs)
                    }
            }
            .buttonStyle(.plain)
            .clipAccessibility(
                label: item.accessibilityDescription(kindLabel: item.kind.label, excerpt: item.excerpt),
                isSelected: selection.contains(item.id),
                action: "Toggle selection"
            )
        } else {
            Button { open(item) } label: {
                tile.overlay(alignment: .topTrailing) {
                    if copiedItemID == item.id {
                        copiedFlash
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
            .buttonStyle(.plain)
            .clipAccessibility(
                label: item.accessibilityDescription(kindLabel: item.kind.label, excerpt: item.excerpt),
                isSelected: isOpen(item),
                action: "Open details"
            )
            .contextMenu { itemMenu(item) } preview: { ClipPeekView(item: item, store: store) }
        }
    }

    private var list: some View {
        List {
            ForEach(ClipSectioning.sections(filtered)) { section in
                Section {
                    ForEach(section.items) { item in listRow(item) }
                } header: {
                    Text(section.label)
                        .font(.yank(.caption, weight: .semibold))
                        .foregroundStyle(Color.yankTextTertiary)
                        .textCase(.uppercase)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await onRetrySync?() }
    }

    @ViewBuilder private func listRow(_ item: ClipboardItem) -> some View {
        if isSelecting {
            Button { toggle(item.id) } label: {
                HStack(spacing: Space.md) {
                    selectionMark(item.id)
                    ClipRowView(item: item, store: store, density: settings.density,
                                isSelected: selection.contains(item.id))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clipAccessibility(
                label: item.accessibilityDescription(kindLabel: item.kind.label, excerpt: item.excerpt),
                isSelected: selection.contains(item.id),
                action: "Toggle selection"
            )
        } else {
            Button { open(item) } label: {
                ClipRowView(item: item, store: store, density: settings.density,
                            isHighlighted: isOpen(item), onTagTap: applyTag)
                    .overlay(alignment: .topTrailing) {
                        if copiedItemID == item.id {
                            copiedFlash
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                                .padding(Space.xs)
                        }
                    }
            }
                .buttonStyle(.plain)
                .clipAccessibility(
                    label: item.accessibilityDescription(kindLabel: item.kind.label, excerpt: item.excerpt),
                    isSelected: isOpen(item),
                    action: "Open details"
                )
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { togglePin(item) } label: {
                        Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                    }.tint(settings.theme.foreground)
                    Button { toggleBookmark(item) } label: {
                        Label(item.isBookmarked ? "Unbookmark" : "Bookmark",
                              systemImage: item.isBookmarked ? "bookmark.slash" : "bookmark")
                    }.tint(Color.yankBookmarkFill)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deleteSingle(item) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { copyClipWithFlash(item) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.tint(settings.theme.foreground)
                }
                .contextMenu { itemMenu(item) } preview: { ClipPeekView(item: item, store: store) }
        }
    }

    private var copiedFlash: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .font(.yank(.caption, weight: .semibold))
            .foregroundStyle(Color.yankOnSuccess)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .background(Color.yankSuccessFill, in: Capsule())
    }

    private func selectionMark(_ id: UUID) -> some View {
        let on = selection.contains(id)
        return Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(.title2))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: ControlTarget.touch, height: ControlTarget.touch)
            .accessibilityLabel(on ? "Selected" : "Not selected")
    }

    @ViewBuilder private func itemMenu(_ item: ClipboardItem) -> some View {
        Button { copyClipWithFlash(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { togglePin(item) } label: {
            Label(item.isPinned ? "Unpin" : "Pin to top", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Button { toggleBookmark(item) } label: {
            Label(item.isBookmarked ? "Remove Bookmark" : "Bookmark",
                  systemImage: item.isBookmarked ? "bookmark.slash" : "bookmark")
        }
        Button(role: .destructive) { deleteSingle(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                if let activeTag {
                    TagChip(label: activeTag, displayPrefix: "#", onRemove: clearTag)
                        .transition(tagChipTransition)
                }
                ForEach(displayedTags.filter { $0 != activeTag }, id: \.self) { tag in
                    TagChip(label: tag, displayPrefix: "#", onTap: { applyTag(tag) })
                        .transition(tagChipTransition)
                }
            }
        }
    }

    private var tagChipTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity)
    }

    // MARK: - Tag autocomplete

    private func applyTag(_ tag: String) {
        withAnimation(IOSMotion.state(reduceMotion)) {
            activeTag = tag
            if query.hasPrefix("#") { query = "" }
        }
    }

    private func clearTag() {
        withAnimation(IOSMotion.state(reduceMotion)) { activeTag = nil }
    }

    private func applyTagSuggestion() {
        guard let tag = TagSuggestions.completion(searchText: query, in: store.allTags) else { return }
        applyTag(tag)
    }

    // MARK: - Single-item actions

    private func copyClip(_ item: ClipboardItem) {
        Task { @MainActor in
            guard await store.copyToPasteboard(item) else { return }
            successPulse += 1
        }
    }

    private func copyClipWithFlash(_ item: ClipboardItem) {
        Task { @MainActor in
            guard await store.copyToPasteboard(item) else { return }
            successPulse += 1
            UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")
            withAnimation(IOSMotion.state(reduceMotion)) { copiedItemID = item.id }
            try? await Task.sleep(for: .milliseconds(1_200))
            withAnimation(IOSMotion.state(reduceMotion)) {
                if copiedItemID == item.id { copiedItemID = nil }
            }
        }
    }

    private func togglePin(_ item: ClipboardItem) {
        store.togglePin(item)
        successPulse += 1
    }

    private func toggleBookmark(_ item: ClipboardItem) {
        store.toggleBookmark(item)
        successPulse += 1
    }

    private func deleteSingle(_ item: ClipboardItem) {
        stageDelete([item])
    }

    private func stageDelete(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        warningPulse += 1
        store.delete(items)
        UIAccessibility.post(notification: .announcement,
                             argument: "\(undoMessage(count: items.count)). Double tap Undo to restore.")
        armCommitTimer(true)
    }

    private func armCommitTimer(_ isPending: Bool) {
        commitTask?.cancel()
        guard isPending else { return }
        commitTask = Task {
            try? await Task.sleep(for: .seconds(PendingDeletePolicy.undoWindowSeconds))
            guard !Task.isCancelled else { return }
            commitDelete()
        }
    }

    private func performUndo() {
        withAnimation(IOSMotion.state(reduceMotion)) { store.undoPendingDelete() }
    }

    private func commitDelete() {
        withAnimation(IOSMotion.state(reduceMotion)) { store.commitPendingDelete() }
    }

    private func undoMessage(count: Int) -> String {
        PendingDeletePolicy.deletedMessage(count: count)
    }

    // MARK: - Selection

    private func open(_ item: ClipboardItem) {
        IOSMotion.selectionFeedback()
        withAnimation(IOSMotion.present(reduceMotion)) { openItem = item }
    }

    private func enterSelection() {
        IOSMotion.selectionFeedback()
        withAnimation(IOSMotion.state(reduceMotion)) {
            isSelecting = true
            selection = []
        }
    }

    private func exitSelection() {
        withAnimation(IOSMotion.state(reduceMotion)) {
            isSelecting = false
            selection = []
        }
    }

    private func toggle(_ id: UUID) {
        IOSMotion.selectionFeedback()
        withAnimation(IOSMotion.quick(reduceMotion)) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }

    private func toggleSelectAll() {
        IOSMotion.selectionFeedback()
        withAnimation(IOSMotion.state(reduceMotion)) {
            selection = allSelected ? [] : Set(filtered.map(\.id))
        }
    }

    private func applyPin() {
        store.setPinned(!selectedAllPinned, for: selectedItems)
        successPulse += 1
        exitSelection()
    }

    private func applyBookmark() {
        store.setBookmarked(!selectedAllBookmarked, for: selectedItems)
        successPulse += 1
        exitSelection()
    }

    private func deleteSelection() {
        let items = selectedItems
        exitSelection()
        stageDelete(items)
    }

    private func shareSelection() {
        let items = selectedItems
        Task { @MainActor in
            let payload = await store.shareItems(for: items)
            guard !payload.isEmpty else { return }
            shareItems = payload
            showShare = true
        }
    }
}
