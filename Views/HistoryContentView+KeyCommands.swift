import SwiftUI

// The GlobalKeyMonitor handler table and the command implementations it dispatches to.
extension HistoryContentView {
    var keyboardHandlers: GlobalKeyMonitor.Handlers {
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

    func moveKeyboardFocus(by delta: Int) {
        scrollTrigger = true
        navigateBy(delta)
    }

    func extendKeyboardSelection(by delta: Int) {
        scrollTrigger = true
        if delta < 0 {
            extendSelectionUp()
        } else {
            extendSelectionDown()
        }
    }

    func handleEnterCommand() {
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

    func handleEscapeCommand() {
        if detail.showTagInput {
            // The field's close handler also closes a peek that was opened only for tagging.
            detail.cancelTagInput()
        } else if showQuickLook {
            dismissQuickLook()
        } else if selectedIDs.count > 1 {
            // Collapse multi-selection back to the focused clip before the next Escape dismisses.
            if let id = selectedID { selectSingle(id) }
        } else if !searchText.isEmpty {
            searchText = ""
        } else {
            onDismiss()
        }
    }

    func deleteFocusedClip() {
        if let item = selectedItem { store.delete(item) }
    }

    func deleteClipWithUndo(_ item: ClipboardItem) {
        store.delete(item)
        scheduleUndoWindowCommit()
    }

    func deleteFocusedClips() {
        if selectedIDs.count > 1 {
            let items = selectedItems
            if let id = selectedID { selectSingle(id) }
            store.deleteItems(items)
        } else {
            deleteFocusedClip()
        }
        scheduleUndoWindowCommit()
    }

    // MARK: - Menu and hover-strip actions

    /// Pin, Bookmark and Add Tag act on the clicked clip only. Paste, Copy and Delete act on the
    /// whole selection when the clicked clip is part of a multi-selection, otherwise on the
    /// clicked clip. None of them changes the selection except Add Tag.
    func clipActions(for item: ClipboardItem) -> ClipActions {
        ClipActions(
            paste: { pasteFromMenu(item) },
            copy: { copyFromMenu(item) },
            togglePin: { store.togglePin(for: item) },
            toggleBookmark: { store.toggleBookmark(for: item) },
            addTag: { addTag(to: item) },
            delete: { deleteFromMenu(item) }
        )
    }

    private func isPartOfMultiSelection(_ item: ClipboardItem) -> Bool {
        selectedIDs.count > 1 && selectedIDs.contains(item.id)
    }

    private func pasteFromMenu(_ item: ClipboardItem) {
        if isPartOfMultiSelection(item) {
            onPasteMultiple(selectedItems)
        } else {
            pasteWithPulse(item)
        }
    }

    private func copyFromMenu(_ item: ClipboardItem) {
        if isPartOfMultiSelection(item) {
            copyFocusedClips()
        } else {
            onCopyToClipboard(item)
            confirmCopy()
        }
    }

    private func deleteFromMenu(_ item: ClipboardItem) {
        if isPartOfMultiSelection(item) {
            store.deleteItems(selectedItems)
        } else {
            store.delete(item)
        }
        scheduleUndoWindowCommit()
        // A soft delete does not bump the store's change token, so repair the selection here.
        updateSelection { $0.reconcile(with: filteredItems) }
    }

    /// Collapses the selection to `item` and shows its tag field: in the detail pane in Split,
    /// otherwise in the peek card, which closes again together with the field.
    func addTag(to item: ClipboardItem) {
        selectSingle(item.id)
        pendingTagInput = item.id
        tagRequestToken &+= 1
        if viewMode != .split, !showQuickLook {
            tagPeekOwned = true
            withAnimation(YankMotion.present(reduceMotion)) { showQuickLook = true }
        }
    }

    /// Restores the pending delete, if any. Returns whether there was one to restore.
    @discardableResult
    func undoPendingDelete() -> Bool {
        guard store.pendingDeletion != nil else { return false }
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = nil
        store.undoPendingDelete()
        return true
    }

    func undoMessage(count: Int) -> String {
        PendingDeletePolicy.deletedMessage(count: count)
    }

    func scheduleUndoWindowCommit() {
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PendingDeletePolicy.undoWindowSeconds))
            guard !Task.isCancelled else { return }
            store.commitPendingDeleteIfNeeded()
            pendingDeleteCommitTask = nil
        }
    }

    func copyFocusedClips() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        if items.count == 1 {
            onCopyToClipboard(items[0])
        } else {
            onCopyMultipleToClipboard(items)
        }
        confirmCopy(count: items.count)
    }

    func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func confirmCopy(count: Int = 1) {
        announce(count == 1 ? "Copied to clipboard" : "\(count) clips copied to clipboard")
        copyConfirmationTask?.cancel()
        showCopyConfirmation = true
        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            showCopyConfirmation = false
        }
    }

    func toggleFocusedPin() {
        if let item = selectedItem { store.togglePin(for: item) }
    }

    func toggleFocusedBookmark() {
        if let item = selectedItem { store.toggleBookmark(for: item) }
    }

    func saveFocusedImage() {
        if let item = selectedItem, item.type == .image { detail.saveImageToDisk(item) }
    }

    func beginFocusedTagInput() {
        if let item = filteredItems.first(where: { $0.id == selectedID }) ?? selectedItem {
            addTag(to: item)
        }
    }

    @discardableResult
    func completeCurrentTag() -> Bool {
        if detail.showTagInput {
            if let item = selectedItem { detail.completeTag(for: item) }
            return true
        }
        if searchText.hasPrefix("#") {
            return applySearchTagCompletion()
        }
        return false
    }

    func clearActiveTagWithBackspace() -> Bool {
        guard isSearchFocused, searchText.isEmpty, activeTagFilter != nil else { return false }
        activeTagFilter = nil
        searchTextDebounced = ""
        return true
    }

    func pasteQuickIndex(_ index: Int) {
        if let item = filteredItem(at: index - 1) { onPaste(item) }
    }

    func pasteFocusedAsText() {
        if let item = selectedItem { onPasteAsText(item) }
    }

    func toggleQuickLookFromKeyboard() -> Bool {
        guard searchText.isEmpty, !detail.showTagInput, selectedItem != nil else { return false }
        withAnimation(YankMotion.present(reduceMotion)) { showQuickLook.toggle() }
        return true
    }

    func moveTiledFocusHorizontally(by delta: Int) -> Bool {
        guard viewMode.isTiled, searchText.isEmpty, !detail.showTagInput, !showQuickLook else { return false }
        moveKeyboardFocus(by: delta)
        return true
    }

    func applySearchTagCompletion() -> Bool {
        guard let match = TagSuggestions.completion(searchText: searchText, in: store.allTags) else { return false }
        activeTagFilter = match
        searchText = ""
        searchTextDebounced = ""
        showTagAutocomplete = false
        return true
    }
}
