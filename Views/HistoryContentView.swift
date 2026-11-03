import Cocoa
import SwiftUI
import ApplicationServices

/// Coordinator for the history window: search, selection, the clip stream, and the key
/// monitor. Split across same-type extensions: `+Selection`, `+KeyCommands`, `+Layouts`, `+ImageExport`.
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
    @State var scrollTrigger = false
    /// Open steps still owed to the next key event after a real open. Regaining key focus
    /// without a new open leaves it empty, so the selection and scroll position stay put.
    /// Starts with the steps for the first open, which can happen before this view listens
    /// for the "shown" notification.
    @State var pendingOpenSteps: Set<OpenStep>

    /// Each receiver of the key event consumes only its own step, so handler order never matters.
    enum OpenStep: Hashable {
        case selectDefault
        case scrollStream
        case scrollSplitRail
    }

    @State var selectedIDs: Set<UUID> = []
    @State var selectionAnchor: UUID?

    @State var activeTagFilter: String? = nil
    @State var showTagAutocomplete: Bool = false

    // Track selection by ID so it survives list insertions
    @State var selectedID: UUID?

    // Space bar peeks the focused clip.
    @State var showQuickLook = false
    /// The clip an Add Tag request is waiting to open the tag field for; consumed by the detail load.
    @State var pendingTagInput: UUID?
    /// Bumped on every Add Tag request so the detail load re-runs even when nothing else changed.
    @State var tagRequestToken = 0
    /// The peek was opened only to show the tag field, so it closes together with the field.
    @State var tagPeekOwned = false

    @State var searchTextDebounced = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State var pendingDeleteCommitTask: Task<Void, Never>?

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
        self.onCopyToClipboard = onCopyToClipboard
        self.onCopyMultipleToClipboard = onCopyMultipleToClipboard
        self.onPaste = onPaste
        self.onPasteAsText = onPasteAsText
        self.onPasteMultiple = onPasteMultiple
        self.onDismiss = onDismiss
        self.onSettingsActiveChange = onSettingsActiveChange
        self.appStatus = appStatus
        _detail = State(initialValue: ClipDetailModel(store: store))
        _pendingOpenSteps = State(initialValue: Self.openSteps(for: SettingsManager.shared.viewMode))
    }

    /// The selection step plus the scroll step of the layout that is on screen, so a hidden
    /// layout cannot hold a stale step.
    static func openSteps(for viewMode: ClipViewMode) -> Set<OpenStep> {
        [.selectDefault, viewMode == .split ? .scrollSplitRail : .scrollStream]
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

    func setSettings(_ on: Bool) {
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
            if store.heldClipCount > 0 {
                HeldClipsNotice(count: store.heldClipCount)
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
                focusedItemHasOCR: selectedItem?.type == .image && selectedItem?.recognizedText != nil,
                quickLookAvailable: searchText.isEmpty && !detail.showTagInput && selectedItem != nil,
                axUntrusted: axUntrusted,
                onGrantAccess: { axPermission?.openSettingsAndAwaitGrant() }
            )

            if let pending = store.pendingDeletion {
                UndoDeleteBanner(
                    message: undoMessage(count: pending.items.count),
                    onUndo: { undoPendingDelete() }
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
        .onReceive(NotificationCenter.default.publisher(for: .yankHistoryWindowDidShow)) { _ in
            searchText = ""
            searchTextDebounced = ""
            activeTagFilter = nil
            pendingOpenSteps = Self.openSteps(for: viewMode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .yankWindowDidOpen)) { _ in
            axPermission?.refresh()
            keepWindowOpen = settings.keepHistoryWindowOpen
            store.commitPendingDeleteIfNeeded()
            showTagAutocomplete = false
            showQuickLook = false
            tagPeekOwned = false
            pendingTagInput = nil
            detail.cancelTagInput()
            if pendingOpenSteps.remove(.selectDefault) != nil {
                let targetID = HistoryOpeningPosition.selectionID(in: filteredItems)
                scrollTrigger = false
                updateSelection { $0.selectDefault(in: filteredItems, preferredID: targetID) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isSearchFocused = true
            }
        }
        .task(id: detailLoadKey) {
            let tagRequest = pendingTagInput
            pendingTagInput = nil
            guard showQuickLook || viewMode == .split else { return }
            let item = selectedItem
            await detail.load(item, beginTagInput: tagRequest != nil && tagRequest == item?.id)
        }
        .onChange(of: detail.showTagInput) { _, isOpen in
            // Every way of closing the field (Return, Esc, Cancel, a suggestion) ends here, so a
            // peek opened only for tagging goes with it and focus always returns to the search field.
            guard !isOpen else { return }
            if tagPeekOwned {
                dismissQuickLook()
            } else {
                isSearchFocused = true
            }
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
        return quickLook + "-" + mode + "-" + selection + "-" + String(tagRequestToken)
    }

    private var quickLookTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }

    private var tagSuggestionsTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// The single way the peek closes: the scrim, the close button, Esc and the tag flow all
    /// come through here, so the tag field never outlives the peek and search regains focus.
    func dismissQuickLook() {
        detail.cancelTagInput()
        pendingTagInput = nil
        tagPeekOwned = false
        isSearchFocused = true
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
