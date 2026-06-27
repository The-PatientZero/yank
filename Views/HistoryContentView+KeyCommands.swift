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

    func undoPendingDelete() {
        pendingDeleteCommitTask?.cancel()
        pendingDeleteCommitTask = nil
        store.undoPendingDelete()
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
        if selectedItem != nil { detail.beginAddTag() }
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
