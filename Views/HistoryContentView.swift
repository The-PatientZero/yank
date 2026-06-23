import Cocoa
import SwiftUI
import ApplicationServices

/// Coordinator for the history window: search, selection, the clip stream, and the
/// key monitor. The focused clip's preview/detail lives in `ClipDetailView` + `ClipDetailModel`.
struct HistoryContentView: View {
    var store: ClipboardStore
    var axPermission: AccessibilityPermission? = nil

    /// Whether auto-paste is blocked for lack of Accessibility access. Reads the shared, observable
    /// `AccessibilityPermission` so the footer hint tracks grants live and stays in step with the
    /// same flag shown in Settings (one source of truth, not a private snapshot).
    private var axUntrusted: Bool { !(axPermission?.isTrusted ?? AXIsProcessTrusted()) }
    /// Set by the controller when the window has been closed long enough (or first open);
    /// the view resets search/tag state once, then writes false back.
    @Binding var shouldResetOnOpen: Bool
    /// Last selected item UUID, kept on the controller so it survives SwiftUI state resets.
    @Binding var savedSelectedID: UUID?
    let onCopyToClipboard: (ClipboardItem) -> Void
    let onCopyMultipleToClipboard: ([ClipboardItem]) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onPasteAsText: (ClipboardItem) -> Void
    let onPasteMultiple: ([ClipboardItem]) -> Void
    let onDismiss: () -> Void
    /// Tells the window whether the Settings screen is showing, so it can stop
    /// closing on click-outside while the user is in Settings.
    let onSettingsActiveChange: (Bool) -> Void
    var appStatus: AppStatus? = nil

    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCopyConfirmation = false
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var themeID = SettingsManager.shared.themeID
    @State private var viewMode = SettingsManager.shared.viewMode
    @State private var density = SettingsManager.shared.density
    @State private var keepWindowOpen = SettingsManager.shared.keepHistoryWindowOpen
    @State private var streamWidth: CGFloat = 460
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var scrollTrigger = false  // Triggers scroll on keyboard navigation

    // Multi-select state
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?

    // Tag filter state
    @State private var activeTagFilter: String? = nil
    @State private var showTagAutocomplete: Bool = false

    // Track selection by ID so it survives list insertions
    @State private var selectedID: UUID?

    // Quick Look overlay (Space peeks the focused clip)
    @State private var showQuickLook = false

    @State private var searchTextDebounced = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var pendingDeleteCommitTask: Task<Void, Never>?

    // The focused clip's preview/OCR/tag-input state + loading.
    @State private var detail: ClipDetailModel

    /// Cards carry this namespace so they glide between layouts when the mode changes.
    @Namespace private var cardNS
    /// The card mid-"yank" — briefly scaled before paste dismisses the window.
    @State private var pulseID: UUID?

    /// Memoised masonry column buckets — rebuilt only when the data, column count, or
    /// active filter changes (see `masonryKey`), not on every selection move or hover.
    @State private var masonryColumns: [[(offset: Int, element: ClipboardItem)]] = []

    init(store: ClipboardStore,
         axPermission: AccessibilityPermission? = nil,
         shouldResetOnOpen: Binding<Bool>,
         savedSelectedID: Binding<UUID?>,
         onCopyToClipboard: @escaping (ClipboardItem) -> Void,
         onCopyMultipleToClipboard: @escaping ([ClipboardItem]) -> Void,
         onPaste: @escaping (ClipboardItem) -> Void,
         onPasteAsText: @escaping (ClipboardItem) -> Void,
         onPasteMultiple: @escaping ([ClipboardItem]) -> Void,
         onDismiss: @escaping () -> Void,
         onSettingsActiveChange: @escaping (Bool) -> Void = { _ in },
         appStatus: AppStatus? = nil) {
        self.store = store
        self.axPermission = axPermission
        _shouldResetOnOpen = shouldResetOnOpen
        _savedSelectedID = savedSelectedID
        self.onCopyToClipboard = onCopyToClipboard
        self.onCopyMultipleToClipboard = onCopyMultipleToClipboard
        self.onPaste = onPaste
        self.onPasteAsText = onPasteAsText
        self.onPasteMultiple = onPasteMultiple
        self.onDismiss = onDismiss
        self.onSettingsActiveChange = onSettingsActiveChange
        self.appStatus = appStatus
        _detail = State(initialValue: ClipDetailModel(store: store))
    }

    private var filteredItems: [ClipboardItem] {
        store.filteredItems(search: searchTextDebounced, activeTag: activeTagFilter)
    }

    private func filteredItem(at index: Int) -> ClipboardItem? {
        filteredItems.indices.contains(index) ? filteredItems[index] : nil
    }

    private var tagSuggestions: [String] {
        TagSuggestions.matching(searchText: searchTextDebounced, in: store.allTags)
    }

    /// Get the first unpinned item, or the first pinned item if no unpinned items exist
    private var defaultSelectedItem: ClipboardItem? {
        return filteredItems.first(where: { !$0.isPinned }) ?? filteredItems.first
    }

    /// All selected items in filtered list order
    private var selectedItems: [ClipboardItem] {
        filteredItems.filter { selectedIDs.contains($0.id) }
    }

    /// The primary selected item (first in list order)
    private var selectedItem: ClipboardItem? {
        selectedItems.first
    }

    private var splitRailWidth: CGFloat {
        HistoryLayout.splitRailWidth(for: streamWidth)
    }

    private var singleClickPastesInCurrentLayout: Bool {
        SettingsManager.shared.clickToPasteInQuickViews && viewMode != .split
    }

    private var rowTagFilterAction: ((String) -> Void)? {
        singleClickPastesInCurrentLayout ? nil : { tag in activeTagFilter = tag }
    }

    private var currentSelectionState: ClipSelectionState {
        ClipSelectionState(
            selectedIDs: selectedIDs,
            anchorID: selectionAnchor,
            focusedID: selectedID,
            focusedIndex: selectedIndex
        )
    }

    private func applySelectionState(_ state: ClipSelectionState) {
        selectedIDs = state.selectedIDs
        selectionAnchor = state.anchorID
        selectedID = state.focusedID
        selectedIndex = state.focusedIndex
    }

    private func updateSelection(_ mutate: (inout ClipSelectionState) -> Void) {
        var state = currentSelectionState
        mutate(&state)
        applySelectionState(state)
    }

    // MARK: - Selection Helpers

    private func selectSingle(_ id: UUID) {
        updateSelection { $0.selectSingle(id, in: filteredItems) }
    }

    private func toggleSelection(_ id: UUID) {
        updateSelection { $0.toggle(id, in: filteredItems) }
    }

    private func extendSelectionTo(_ targetID: UUID) {
        updateSelection { $0.extend(to: targetID, in: filteredItems) }
    }

    private func extendSelectionUp() {
        updateSelection { $0.extendByOne(-1, in: filteredItems) }
    }

    private func extendSelectionDown() {
        updateSelection { $0.extendByOne(1, in: filteredItems) }
    }

    /// Download all selected images to a folder
    private func downloadAllImages() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.title = "Select Folder to Save Images"
        openPanel.prompt = "Select"

        if let window = NSApplication.shared.windows.first {
            openPanel.beginSheetModal(for: window) { response in
                guard response == .OK, let folderURL = openPanel.url else { return }
                // Blob-copy I/O is the store's job — it owns the blob layout. The
                // view just hands over the selected clips and the destination folder.
                do {
                    try store.exportImages(selectedItems, to: folderURL)
                } catch {
                    Log.app.error("Failed to export images: \(error.localizedDescription)")
                }
            }
        }
    }

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(
                    onBack: { setSettings(false) },
                    store: store,
                    axPermission: axPermission,
                    appStatus: appStatus
                )
                    .transition(screenTransition(edge: .trailing))
            } else {
                historyScreen
                    .transition(screenTransition(edge: .leading))
            }
        }
        .animation(YankMotion.navigation(reduceMotion), value: showSettings)
        .onChange(of: showSettings) { _, newValue in
            onSettingsActiveChange(newValue)
            if !newValue { keepWindowOpen = SettingsManager.shared.keepHistoryWindowOpen }
        }
        .onReceive(NotificationCenter.default.publisher(for: .yankOpenSettings)) { _ in setSettings(true) }
        .onReceive(NotificationCenter.default.publisher(for: .yankWindowDidOpen)) { _ in showSettings = false }
    }

    private func setSettings(_ on: Bool) {
        withAnimation(YankMotion.navigation(reduceMotion)) { showSettings = on }
    }

    private func screenTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var historyScreenBody: some View {
        VStack(spacing: 0) {
            if store.storageUnavailable {
                StorageUnavailableBanner()
            }

            HistorySearchHeader(
                searchText: $searchText,
                activeTagFilter: $activeTagFilter,
                viewMode: $viewMode,
                isSearchFocused: $isSearchFocused,
                hasTags: !store.allTags.isEmpty,
                count: filteredItems.count,
                keepWindowOpen: keepWindowOpen,
                reduceMotion: reduceMotion,
                onSettings: { setSettings(true) }
            )

            if showTagAutocomplete && !tagSuggestions.isEmpty {
                TagAutocompleteBar(suggestions: tagSuggestions) { tag in
                    activeTagFilter = tag
                    searchText = ""
                    showTagAutocomplete = false
                }
                .transition(tagSuggestionsTransition)
            }

            if viewMode == .split {
                splitLayout
            } else {
                stream
            }

            FooterHintsBar(
                selectionCount: selectedIDs.count,
                clickToPaste: singleClickPastesInCurrentLayout,
                hasPendingUndo: store.pendingDeletion != nil,
                focusedItemHasOCR: selectedItem?.type == .image && selectedItem?.ocrText != nil,
                quickLookAvailable: searchText.isEmpty && !detail.showTagInput && selectedItem != nil,
                axUntrusted: axUntrusted,
                onGrantAccess: { axPermission?.openSettingsAndAwaitGrant() }
            )

            if let pending = store.pendingDeletion {
                UndoDeleteBanner(
                    message: undoMessage(count: pending.items.count),
                    onUndo: undoPendingDelete
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: HistoryLayout.minWidth, minHeight: HistoryLayout.minHeight)
        .animation(YankMotion.state(reduceMotion), value: store.pendingDeletion != nil)
        .onChange(of: store.pendingDeletion?.items.count) { _, count in
            if let count {
                announce("\(count) \(count == 1 ? "clip" : "clips") deleted. Command Z to undo.")
            }
        }
        .background(widthReader)
        .background(streamBackground)
        .overlay {
            if showQuickLook, selectedItem != nil {
                ClipQuickLookOverlay(
                    store: store, selectedItems: selectedItems, model: detail,
                    onCopy: onCopyToClipboard, onDownloadImages: downloadAllImages,
                    onDelete: deleteClipWithUndo,
                    onDismiss: { dismissQuickLook() }
                )
                .transition(quickLookTransition)
            }
        }
        .overlay(alignment: .bottom) {
            if showCopyConfirmation {
                CopyConfirmationCapsule()
                    .padding(.bottom, Space.xxxl)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(YankMotion.present(reduceMotion), value: showCopyConfirmation)
        .animation(YankMotion.state(reduceMotion), value: showTagAutocomplete)
        .animation(YankMotion.present(reduceMotion), value: showQuickLook)
    }

    private var historyScreen: some View {
        historyScreenBody
        .onChange(of: searchText) { _, newValue in
            showTagAutocomplete = newValue.hasPrefix("#")
            searchDebounceTask?.cancel()
            if newValue.hasPrefix("#") || newValue.isEmpty {
                searchTextDebounced = newValue
                updateSelection { $0.selectDefault(in: filteredItems, preferredID: defaultSelectedItem?.id) }
            } else {
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    searchTextDebounced = newValue
                    updateSelection { $0.selectDefault(in: filteredItems, preferredID: defaultSelectedItem?.id) }
                }
            }
        }
        .onChange(of: selectedIndex) { _, newIndex in
            selectedID = filteredItem(at: newIndex)?.id
        }
        .onChange(of: selectedID) { _, newValue in
            savedSelectedID = newValue
        }
        .onChange(of: store.changeToken) { _, _ in
            guard let id = selectedID else { return }
            updateSelection { state in
                if filteredItems.contains(where: { $0.id == id }) {
                    state.focusedID = id
                }
                state.reconcile(with: filteredItems)
            }
        }
        .onChange(of: masonryKey) { _, _ in rebuildMasonryIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .yankWindowDidOpen)) { _ in
            axPermission?.refresh()
            keepWindowOpen = SettingsManager.shared.keepHistoryWindowOpen
            store.commitPendingDeleteIfNeeded()
            if shouldResetOnOpen {
                searchText = ""
                searchTextDebounced = ""
                activeTagFilter = nil
            }
            showTagAutocomplete = false
            showQuickLook = false
            detail.cancelTagInput()
            let targetID: UUID?
            if !shouldResetOnOpen,
               let saved = savedSelectedID,
               filteredItems.contains(where: { $0.id == saved }) {
                targetID = saved
            } else {
                targetID = (filteredItems.first(where: { !$0.isPinned }) ?? filteredItems.first)?.id
            }
            updateSelection { $0.selectDefault(in: filteredItems, preferredID: targetID) }
            scrollTrigger = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isSearchFocused = true
            }
        }
        .task(id: detailLoadKey) {
            if showQuickLook || viewMode == .split { await detail.load(selectedItem) }
        }
        .background(GlobalKeyMonitor(handlers: keyboardHandlers))
        .tint(AppTheme.from(id: themeID).foreground)
        .onReceive(NotificationCenter.default.publisher(for: .yankThemeChanged)) { _ in
            themeID = SettingsManager.shared.themeID
        }
        .onReceive(NotificationCenter.default.publisher(for: .yankAppearanceChanged)) { _ in
            withAnimation(YankMotion.navigation(reduceMotion)) {
                viewMode = SettingsManager.shared.viewMode
                density = SettingsManager.shared.density
            }
        }
    }

    private var detailLoadKey: String {
        let quickLook = showQuickLook ? "1" : "0"
        let mode = viewMode.rawValue
        let selection = selectedItem?.id.uuidString ?? ""
        return quickLook + "-" + mode + "-" + selection
    }

    private var quickLookTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }

    private var tagSuggestionsTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private func dismissQuickLook() {
        withAnimation(YankMotion.present(reduceMotion)) { showQuickLook = false }
    }

    private var streamBackground: some View { YankWindowBackground() }

    private var keyboardHandlers: GlobalKeyMonitor.Handlers {
        GlobalKeyMonitor.Handlers(
            onUp: { moveKeyboardFocus(by: viewMode.isTiled ? -tileColumnCount : -1) },
            onDown: { moveKeyboardFocus(by: viewMode.isTiled ? tileColumnCount : 1) },
            onExtendUp: { extendKeyboardSelection(by: -1) },
            onExtendDown: { extendKeyboardSelection(by: 1) },
            onEnter: handleEnterCommand,
            onEscape: handleEscapeCommand,
            onDelete: deleteFocusedClips,
            onCopy: copyFocusedClips,
            onPin: toggleFocusedPin,
            onBookmark: toggleFocusedBookmark,
            onSaveImage: saveFocusedImage,
            onAddTag: beginFocusedTagInput,
            onTabComplete: { completeCurrentTag() },
            onBackspace: clearActiveTagWithBackspace,
            onPasteIndex: pasteQuickIndex,
            onPasteAsTextKey: pasteFocusedAsText,
            onSpace: toggleQuickLookFromKeyboard,
            onLeft: { moveTiledFocusHorizontally(by: -1) },
            onRight: { moveTiledFocusHorizontally(by: 1) },
            onUndo: undoPendingDelete,
            onFocusSearch: { isSearchFocused = true }
        )
    }

    // MARK: - Keyboard commands

    private func moveKeyboardFocus(by delta: Int) {
        scrollTrigger = true
        navigateBy(delta)
    }

    private func extendKeyboardSelection(by delta: Int) {
        scrollTrigger = true
        if delta < 0 {
            extendSelectionUp()
        } else {
            extendSelectionDown()
        }
    }

    private func handleEnterCommand() {
        if detail.showTagInput {
            if let item = selectedItem {
                detail.commitTag(to: item)
            } else {
                detail.cancelTagInput()
            }
        } else if applySearchTagCompletion() {
            return
        } else if selectedItems.count > 1 {
            onPasteMultiple(Array(selectedItems))
        } else if let item = selectedItem {
            pasteWithPulse(item)
        }
    }

    private func handleEscapeCommand() {
        if showQuickLook {
            dismissQuickLook()
        } else if detail.showTagInput {
            detail.cancelTagInput()
        } else if selectedIDs.count > 1 {
            // Collapse multi-selection back to the focused clip before the next Escape dismisses.
            if let id = selectedID { selectSingle(id) }
        } else {
            onDismiss()
        }
    }

    private func deleteFocusedClip() {
        if let item = selectedItem { store.delete(item) }
    }

    private func deleteClipWithUndo(_ item: ClipboardItem) {
        store.delete(item)
        scheduleUndoWindowCommit()
    }

    private func deleteFocusedClips() {
        if selectedIDs.count > 1 {
            let items = selectedItems
            if let id = selectedID { selectSingle(id) }
            store.deleteItems(items)
        } else {
            deleteFocusedClip()
        }
        scheduleUndoWindowCommit()
    }

    private func undoPendingDelete() {
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = nil
        store.undoPendingDelete()
    }

    private func undoMessage(count: Int) -> String {
        count == 1 ? "Clip deleted" : "\(count) clips deleted"
    }

    private func scheduleUndoWindowCommit() {
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PendingDeletePolicy.undoWindowSeconds))
            guard !Task.isCancelled else { return }
            store.commitPendingDeleteIfNeeded()
            pendingDeleteCommitTask = nil
        }
    }

    private func copyFocusedClips() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        if items.count == 1 {
            onCopyToClipboard(items[0])
        } else {
            onCopyMultipleToClipboard(items)
        }
        confirmCopy(count: items.count)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func confirmCopy(count: Int = 1) {
        announce(count == 1 ? "Copied to clipboard" : "\(count) clips copied to clipboard")
        copyConfirmationTask?.cancel()
        showCopyConfirmation = true
        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            showCopyConfirmation = false
        }
    }

    private func toggleFocusedPin() {
        if let item = selectedItem { store.togglePin(for: item) }
    }

    private func toggleFocusedBookmark() {
        if let item = selectedItem { store.toggleBookmark(for: item) }
    }

    private func saveFocusedImage() {
        if let item = selectedItem, item.type == .image { detail.saveImageToDisk(item) }
    }

    private func beginFocusedTagInput() {
        if selectedItem != nil { detail.beginAddTag() }
    }

    @discardableResult
    private func completeCurrentTag() -> Bool {
        if detail.showTagInput {
            if let item = selectedItem { detail.completeTag(for: item) }
            return true
        }
        if searchText.hasPrefix("#") {
            return applySearchTagCompletion()
        }
        return false
    }

    private func clearActiveTagWithBackspace() -> Bool {
        guard isSearchFocused, searchText.isEmpty, activeTagFilter != nil else { return false }
        activeTagFilter = nil
        searchTextDebounced = ""
        return true
    }

    private func pasteQuickIndex(_ index: Int) {
        if let item = filteredItem(at: index - 1) { onPaste(item) }
    }

    private func pasteFocusedAsText() {
        if let item = selectedItem { onPasteAsText(item) }
    }

    private func toggleQuickLookFromKeyboard() -> Bool {
        guard searchText.isEmpty, !detail.showTagInput, selectedItem != nil else { return false }
        withAnimation(YankMotion.present(reduceMotion)) { showQuickLook.toggle() }
        return true
    }

    private func moveTiledFocusHorizontally(by delta: Int) -> Bool {
        guard viewMode.isTiled, searchText.isEmpty, !detail.showTagInput, !showQuickLook else { return false }
        moveKeyboardFocus(by: delta)
        return true
    }

    private func applySearchTagCompletion() -> Bool {
        guard let match = TagSuggestions.completion(searchText: searchText, in: store.allTags) else { return false }
        activeTagFilter = match
        searchText = ""
        searchTextDebounced = ""
        showTagAutocomplete = false
        return true
    }

    // MARK: - Scrolling stream (List / Grid / Masonry / Gallery)

    private var stream: some View {
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
                        HistoryEmptyState(isClear: searchText.isEmpty && activeTagFilter == nil)
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
                if let id = selectedID ?? filteredItems.first?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var streamContent: some View {
        switch viewMode {
        case .list:    listLayout
        case .grid:    tileGrid(columns: [GridItem(.adaptive(minimum: density.tileMinWidth), spacing: density.spacing)])
        case .gallery: tileGrid(columns: [GridItem(.flexible(), spacing: density.spacing), GridItem(.flexible(), spacing: density.spacing)])
        case .masonry: masonryLayout
        case .split:   EmptyView()
        }
    }

    private var listLayout: some View {
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

    private func tileGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: density.spacing) {
            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                selectable(item, index) { tile(item, index) }
            }
        }
    }

    private var masonryLayout: some View {
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
    private struct MasonryKey: Equatable {
        let token: Int
        let columns: Int
        let search: String
        let tag: String?
        let isMasonry: Bool
    }

    private var masonryKey: MasonryKey {
        MasonryKey(
            token: store.changeToken,
            columns: max(2, tileColumnCount),
            search: searchText,
            tag: activeTagFilter,
            isMasonry: viewMode == .masonry
        )
    }

    private func rebuildMasonryIfNeeded() {
        guard viewMode == .masonry else { return }
        let columnCount = max(2, tileColumnCount)
        var buckets: [[(offset: Int, element: ClipboardItem)]] = Array(repeating: [], count: columnCount)
        for (offset, element) in filteredItems.enumerated() {
            buckets[offset % columnCount].append((offset, element))
        }
        masonryColumns = buckets
    }

    private func tile(_ item: ClipboardItem, _ index: Int) -> some View {
        ClipTile(
            item: item, store: store, mode: viewMode, density: density,
            isPrimarySelection: item.id == selectedID,
            isMultiSelected: selectedIDs.contains(item.id),
            quickKey: index < 9 ? index + 1 : nil,
            pastesOnClick: singleClickPastesInCurrentLayout
        )
    }

    @ViewBuilder
    private func selectable<Content: View>(_ item: ClipboardItem, _ index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .contentShape(Rectangle())
            // A keyboard-focus ring on the primary-selected cell — the list's keyboard
            // cursor, which is always live here (arrow keys navigate the stream app-wide
            // via GlobalKeyMonitor, even while the search field types). It's the system
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
    /// ring can show at full strength. Arrow keys are routed app-wide by `GlobalKeyMonitor`
    /// regardless, but the only place AppKit draws its own focus ring is the search field —
    /// so the cursor ring dims (rather than competes) while the field is being typed into.
    private var listHasKeyboardFocus: Bool { !isSearchFocused }

    /// A subtle drag image reusing the tile, so what lifts off the stream reads as the
    /// same clip. Width-bounded so a long row doesn't drag an oversized ghost.
    private func dragPreview(for item: ClipboardItem) -> some View {
        ClipTile(
            item: item, store: store, mode: .grid, density: density,
            isPrimarySelection: false, isMultiSelected: false
        )
        .frame(width: density.tileMinWidth)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func sectionHeaderView(_ label: String, isFirst: Bool) -> some View {
        Text(label)
            .font(.system(size: TypeScale.micro, weight: .semibold).smallCaps())
            .foregroundColor(.yankTextTertiary)
            .padding(.horizontal, Space.md)
            .padding(.top, isFirst ? 0 : Space.lg)
            .padding(.bottom, Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { streamWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newValue in streamWidth = newValue }
        }
    }

    // MARK: - Split mode (rail + live preview)

    private var splitLayout: some View {
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
                    HistoryEmptyState(isClear: searchText.isEmpty && activeTagFilter == nil)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Move the focus by `delta` items, clamped to the ends. In tiled modes the
    /// callers pass ±columnCount for up/down so a full row is traversed.
    private func navigateBy(_ delta: Int) {
        updateSelection { $0.move(by: delta, in: filteredItems) }
    }

    /// Tiles per row for the current mode/width — the single source of truth shared by
    /// the masonry layout and the up/down row jumps.
    private var tileColumnCount: Int {
        HistoryLayout.tileColumnCount(viewMode: viewMode, streamWidth: streamWidth, density: density)
    }

    /// A quick "yank" — scale the focused card up and out, then paste. Reduce Motion
    /// pastes instantly. Keeps the delay tiny so paste still feels immediate.
    private func pasteWithPulse(_ item: ClipboardItem) {
        guard pulseID == nil else { return }
        announce("Pasted")
        guard !reduceMotion else { onPaste(item); return }
        withAnimation(YankMotion.instant(reduceMotion)) { pulseID = item.id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(YankMotion.pasteDelay))
            onPaste(item)
            pulseID = nil
        }
    }

}
