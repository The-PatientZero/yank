import Foundation
import Testing
@testable import YankCore

@Suite struct ClipSelectionStateTests {
    @Test func defaultSelectionSkipsPinnedWhenPossible() {
        let pinned = item(text: "pinned", pinned: true)
        let normal = item(text: "normal")
        var state = ClipSelectionState()

        state.selectDefault(in: [pinned, normal])

        #expect(state.focusedID == normal.id)
        #expect(state.selectedIDs == [normal.id])
        #expect(state.focusedIndex == 1)
    }

    @Test func rangeSelectionUsesAnchorThroughTarget() {
        let clips = [item(text: "one"), item(text: "two"), item(text: "three")]
        var state = ClipSelectionState()
        state.selectSingle(clips[0].id, in: clips)

        state.extend(to: clips[2].id, in: clips)

        #expect(state.selectedIDs == Set(clips.map(\.id)))
        #expect(state.focusedID == clips[2].id)
        #expect(state.focusedIndex == 2)
    }

    @Test func moveCollapsesMultiSelectionToFocusedTarget() {
        let clips = [item(text: "one"), item(text: "two"), item(text: "three")]
        var state = ClipSelectionState()
        state.selectSingle(clips[0].id, in: clips)
        state.extend(to: clips[2].id, in: clips)

        state.move(by: -1, in: clips)

        #expect(state.selectedIDs == [clips[1].id])
        #expect(state.focusedID == clips[1].id)
        #expect(state.anchorID == clips[1].id)
    }

    @Test func reconcileFallsBackWhenFocusedItemDisappears() {
        let clips = [item(text: "one"), item(text: "two"), item(text: "three")]
        var state = ClipSelectionState()
        state.selectSingle(clips[2].id, in: clips)

        state.reconcile(with: Array(clips.prefix(2)))

        #expect(state.focusedID == clips[1].id)
        #expect(state.selectedIDs == [clips[1].id])
        #expect(state.focusedIndex == 1)
    }

    @Test func plainHistoryItemClickPastesWhenEnabled() {
        let action = ClipClickPolicy.action(
            for: ClipClickModifiers(hasCommand: false, hasShift: false),
            clickCount: 1,
            singleClickPastes: true
        )

        #expect(action == .paste)
    }

    @Test func plainHistoryItemClickSelectsWhenPasteOnClickIsDisabled() {
        let action = ClipClickPolicy.action(
            for: ClipClickModifiers(hasCommand: false, hasShift: false),
            clickCount: 1,
            singleClickPastes: false
        )

        #expect(action == .selectSingle)
    }

    @Test func doubleHistoryItemClickPastesWhenSingleClickSelects() {
        let action = ClipClickPolicy.action(
            for: ClipClickModifiers(hasCommand: false, hasShift: false),
            clickCount: 2,
            singleClickPastes: false
        )

        #expect(action == .paste)
    }

    @Test func commandHistoryItemClickTogglesSelection() {
        let action = ClipClickPolicy.action(
            for: ClipClickModifiers(hasCommand: true, hasShift: false),
            clickCount: 2,
            singleClickPastes: true
        )

        #expect(action == .toggleSelection)
    }

    @Test func shiftHistoryItemClickExtendsSelection() {
        let action = ClipClickPolicy.action(
            for: ClipClickModifiers(hasCommand: false, hasShift: true),
            clickCount: 2,
            singleClickPastes: true
        )

        #expect(action == .extendSelection)
    }

    @Test func commandWinsWhenHistoryItemClickHasMultipleSelectionModifiers() {
        let action = ClipClickPolicy.action(
            for: ClipClickModifiers(hasCommand: true, hasShift: true),
            clickCount: 1,
            singleClickPastes: false
        )

        #expect(action == .toggleSelection)
    }

    private func item(text: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(type: .text, textContent: text, isPinned: pinned)
    }
}
