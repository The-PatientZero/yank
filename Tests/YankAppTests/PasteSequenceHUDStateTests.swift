import Testing
@testable import Yank

@Suite("Paste Sequence HUD")
@MainActor
struct PasteSequenceHUDStateTests {
    @Test("Collecting presentation exposes counts and shortcut only")
    func collectingPresentationIsCountsOnly() {
        let state = PasteSequenceHUDState()
        state.itemCount = 3
        state.shortcut = "⇧⌘V"

        #expect(state.statusText == "3 items copied")
        #expect(state.detailText == "⇧⌘V pastes the first item")
    }

    @Test("Blocked dispatch remains status-only")
    func blockedDispatchRemainsStatusOnly() {
        let state = PasteSequenceHUDState()
        state.phase = .blocked(.pasteboardWriteFailed)

        #expect(state.statusText == "Paste not sent")
        #expect(state.detailText == "The current item is still ready to retry")
    }

    @Test("Accessibility prerequisite explains recovery without owning focus")
    func accessibilityPrerequisiteExplainsRecovery() {
        let state = PasteSequenceHUDState()
        state.phase = .blocked(.accessibilityUnavailable)

        #expect(state.statusText == "Paste not sent")
        #expect(state.detailText == "Accessibility access is required to paste")
    }
}
