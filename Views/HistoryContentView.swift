import Cocoa
import SwiftUI
import ApplicationServices

/// Coordinator for the history window: search, selection, the clip stream, and the
/// key monitor. The focused clip's preview/detail lives in `ClipDetailView` + `ClipDetailModel`.
///
/// The bulk of the view splits into same-type extensions kept in sibling files:
/// `+Selection` (multi-select state bridging to `ClipSelectionState`), `+KeyCommands`
/// (the `GlobalKeyMonitor` table and its handlers), `+Layouts` (list/grid/masonry/
/// gallery/split builders and the `selectable` cell), and `+ImageExport`.
struct HistoryContentView: View {
    var store: ClipboardStore
    var axPermission: AccessibilityPermission? = nil
    /// Injected settings store (the composition root passes its single instance). Defaults to the
    /// shared instance so previews work; the `@State` seeds below read it directly because a
    /// property initializer can't yet reference `self`.
    let settings: SettingsManager

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

    @FocusState var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var showCopyConfirmation = false
    @State var copyConfirmationTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var themeID = SettingsManager.shared.themeID
    @State var viewMode = SettingsManager.shared.viewMode
    @State var density = SettingsManager.shared.density
    @State private var keepWindowOpen = SettingsManager.shared.keepHistoryWindowOpen
    @State var streamWidth: CGFloat = 460
    @State var searchText = ""
    @State var selectedIndex = 0
    @State var scrollTrigger = false  // Triggers scroll on keyboard navigation

    // Multi-select state
    @State var selectedIDs: Set<UUID> = []
    @State var selectionAnchor: UUID?

    // Tag filter state
    @State var activeTagFilter: String? = nil
    @State var showTagAutocomplete: Bool = false

    // Track selection by ID so it survives list insertions
    @State var selectedID: UUID?

    // Quick Look overlay (Space peeks the focused clip)
    @State var showQuickLook = false

    @State var searchTextDebounced = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State var pendingDeleteCommitTask: Task<Void, Never>?

    // The focused clip's preview/OCR/tag-input state + loading.
    @State var detail: ClipDetailModel

    /// Cards carry this namespace so they glide between layouts when the mode changes.
    @Namespace var cardNS
    /// The card mid-"yank" — briefly scaled before paste dismisses the window.
    @State var pulseID: UUID?

    /// Memoised masonry column buckets — rebuilt only when the data, column count, or
    /// active filter changes (see `masonryKey`), not on every selection move or hover.
    @State var masonryColumns: [[(offset: Int, element: ClipboardItem)]] = []

    init(store: ClipboardStore,
         axPermission: AccessibilityPermission? = nil,
         settings: SettingsManager = .shared,
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
        self.settings = settings
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

    var filteredItems: [ClipboardItem] {
        store.filteredItems(search: searchTextDebounced, activeTag: activeTagFilter)
    }

    func filteredItem(at index: Int) -> ClipboardItem? {
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
    var selectedItems: [ClipboardItem] {
        filteredItems.filter { selectedIDs.contains($0.id) }
    }

    /// The primary selected item (first in list order)
    var selectedItem: ClipboardItem? {
        selectedItems.first
    }

    var splitRailWidth: CGFloat {
        HistoryLayout.splitRailWidth(for: streamWidth)
    }

    var singleClickPastesInCurrentLayout: Bool {
        settings.clickToPasteInQuickViews && viewMode != .split
    }

    var rowTagFilterAction: ((String) -> Void)? {
        singleClickPastesInCurrentLayout ? nil : { tag in activeTagFilter = tag }
    }

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(
                    onBack: { setSettings(false) },
                    store: store,
                    axPermission: axPermission,
                    appStatus: appStatus,
                    manager: settings
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
            if !newValue { keepWindowOpen = settings.keepHistoryWindowOpen }
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
            keepWindowOpen = settings.keepHistoryWindowOpen
            store.commitPendingDeleteIfNeeded()
            if shouldResetOnOpen {
                searchText = ""
                searchTextDebounced = ""
                activeTagFilter = nil
            }
            showTagAutocomplete = false
            showQuickLook = false
            detail.cancelTagInput()
            let targetID = HistoryOpeningPosition.selectionID(in: filteredItems)
            scrollTrigger = false
            updateSelection { $0.selectDefault(in: filteredItems, preferredID: targetID) }
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
            themeID = settings.themeID
        }
        .onReceive(NotificationCenter.default.publisher(for: .yankAppearanceChanged)) { _ in
            withAnimation(YankMotion.navigation(reduceMotion)) {
                viewMode = settings.viewMode
                density = settings.density
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

    func dismissQuickLook() {
        withAnimation(YankMotion.present(reduceMotion)) { showQuickLook = false }
    }

    private var streamBackground: some View { YankWindowBackground() }

    /// A quick "yank" — scale the focused card up and out, then paste. Reduce Motion
    /// pastes instantly. Keeps the delay tiny so paste still feels immediate.
    func pasteWithPulse(_ item: ClipboardItem) {
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
