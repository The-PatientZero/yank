import Foundation

/// Pure selection rules for the history stream. The SwiftUI view owns gestures and
/// rendering; this type owns focus, range, and reconciliation semantics.
struct ClipSelectionState: Equatable {
    var selectedIDs: Set<UUID> = []
    var anchorID: UUID?
    var focusedID: UUID?
    var focusedIndex: Int = 0

    func selectedItems(in items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    mutating func clear() {
        selectedIDs = []
        anchorID = nil
        focusedID = nil
        focusedIndex = 0
    }

    mutating func selectDefault(in items: [ClipboardItem], preferredID: UUID? = nil) {
        if let preferredID, items.contains(where: { $0.id == preferredID }) {
            selectSingle(preferredID, in: items)
        } else if let item = items.first(where: { !$0.isPinned }) ?? items.first {
            selectSingle(item.id, in: items)
        } else {
            clear()
        }
    }

    mutating func selectSingle(_ id: UUID, in items: [ClipboardItem]) {
        selectedIDs = [id]
        anchorID = id
        focusedID = id
        focusedIndex = index(of: id, in: items) ?? 0
    }

    mutating func toggle(_ id: UUID, in items: [ClipboardItem]) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        anchorID = id
        focusedID = id
        focusedIndex = index(of: id, in: items) ?? focusedIndex
    }

    mutating func extend(to targetID: UUID, in items: [ClipboardItem]) {
        guard let anchorID else {
            selectSingle(targetID, in: items)
            return
        }
        guard let anchorIndex = index(of: anchorID, in: items),
              let targetIndex = index(of: targetID, in: items) else { return }

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedIDs = Set(items[range].map(\.id))
        focusedID = targetID
        focusedIndex = targetIndex
    }

    mutating func extendByOne(_ delta: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            clear()
            return
        }
        let targetIndex = focusedIndex + delta
        guard items.indices.contains(focusedIndex), items.indices.contains(targetIndex) else { return }

        let currentID = items[focusedIndex].id
        if selectedIDs.isEmpty {
            selectSingle(currentID, in: items)
            return
        }

        let targetID = items[targetIndex].id
        selectedIDs.insert(targetID)
        anchorID = anchorID ?? currentID
        focusedID = targetID
        focusedIndex = targetIndex
    }

    mutating func move(by delta: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            clear()
            return
        }

        let targetIndex = max(0, min(items.count - 1, focusedIndex + delta))
        guard targetIndex != focusedIndex else { return }
        selectSingle(items[targetIndex].id, in: items)
    }

    mutating func reconcile(with items: [ClipboardItem]) {
        selectedIDs = selectedIDs.filter { id in items.contains { $0.id == id } }

        if let focusedID, let newIndex = index(of: focusedID, in: items) {
            focusedIndex = newIndex
            return
        }

        let fallbackIndex = min(focusedIndex, max(items.count - 1, 0))
        if items.indices.contains(fallbackIndex) {
            selectSingle(items[fallbackIndex].id, in: items)
        } else {
            clear()
        }
    }

    private func index(of id: UUID, in items: [ClipboardItem]) -> Int? {
        items.firstIndex { $0.id == id }
    }
}

struct ClipClickModifiers: Equatable, Sendable {
    var hasCommand: Bool
    var hasShift: Bool
}

enum ClipClickAction: Equatable, Sendable {
    case paste
    case selectSingle
    case toggleSelection
    case extendSelection
}

enum ClipClickPolicy {
    static func action(
        for modifiers: ClipClickModifiers,
        clickCount: Int,
        singleClickPastes: Bool
    ) -> ClipClickAction {
        if modifiers.hasCommand { return .toggleSelection }
        if modifiers.hasShift { return .extendSelection }
        if clickCount >= 2 || singleClickPastes { return .paste }
        return .selectSingle
    }
}
