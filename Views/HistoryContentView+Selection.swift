import SwiftUI

// Selection state lives in `@State` on the view; the mutation logic delegates to the
// pure `ClipSelectionState` in YankCore. These helpers bridge the two.
extension HistoryContentView {
    var currentSelectionState: ClipSelectionState {
        ClipSelectionState(
            selectedIDs: selectedIDs,
            anchorID: selectionAnchor,
            focusedID: selectedID,
            focusedIndex: selectedIndex
        )
    }

    func applySelectionState(_ state: ClipSelectionState) {
        selectedIDs = state.selectedIDs
        selectionAnchor = state.anchorID
        selectedID = state.focusedID
        selectedIndex = state.focusedIndex
    }

    func updateSelection(_ mutate: (inout ClipSelectionState) -> Void) {
        var state = currentSelectionState
        mutate(&state)
        applySelectionState(state)
    }

    func selectSingle(_ id: UUID) {
        updateSelection { $0.selectSingle(id, in: filteredItems) }
    }

    func toggleSelection(_ id: UUID) {
        updateSelection { $0.toggle(id, in: filteredItems) }
    }

    func extendSelectionTo(_ targetID: UUID) {
        updateSelection { $0.extend(to: targetID, in: filteredItems) }
    }

    func extendSelectionUp() {
        updateSelection { $0.extendByOne(-1, in: filteredItems) }
    }

    func extendSelectionDown() {
        updateSelection { $0.extendByOne(1, in: filteredItems) }
    }

    /// Move the focus by `delta` items, clamped to the ends. In tiled modes the
    /// callers pass ±columnCount for up/down so a full row is traversed.
    func navigateBy(_ delta: Int) {
        updateSelection { $0.move(by: delta, in: filteredItems) }
    }
}
