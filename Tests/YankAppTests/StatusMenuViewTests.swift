import Testing
@testable import Yank

@Suite("Status Menu View")
@MainActor
struct StatusMenuViewTests {
    @Test("Actionable update row is keyboard focusable")
    func actionableUpdateRowIsKeyboardFocusable() throws {
        let rows = StatusMenuView.orderedRows(hotkeyUnavailable: false, updateAction: .openReleaseNotes)

        let quickPickerIndex = try #require(rows.firstIndex(of: .openQuickPicker))
        let fullHistoryIndex = try #require(rows.firstIndex(of: .openHistory))
        let settingsIndex = try #require(rows.firstIndex(of: .settings))
        let updateIndex = try #require(rows.firstIndex(of: .update))
        let restartIndex = try #require(rows.firstIndex(of: .restart))

        #expect(quickPickerIndex < fullHistoryIndex)
        #expect(fullHistoryIndex < settingsIndex)
        #expect(settingsIndex < updateIndex)
        #expect(updateIndex < restartIndex)
    }

    @Test("Passive update state is not in focus order")
    func passiveUpdateStateIsNotInFocusOrder() {
        let rows = StatusMenuView.orderedRows(hotkeyUnavailable: false, updateAction: nil)

        #expect(!rows.contains(.update))
    }
}
