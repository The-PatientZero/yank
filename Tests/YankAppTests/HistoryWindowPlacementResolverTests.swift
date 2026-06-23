import AppKit
import Testing
@testable import Yank

@Suite("History Window Placement")
struct HistoryWindowPlacementResolverTests {
    @Test("Menu bar anchor opens directly below the icon")
    func attachedFrameOpensBelowAnchor() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let anchorFrame = NSRect(x: 1_000, y: 876, width: 24, height: 24)
        let windowSize = NSSize(width: 460, height: 640)

        let frame = HistoryWindowPlacementResolver.attachedToAnchor(
            anchorFrame: anchorFrame,
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.midX == anchorFrame.midX)
        #expect(frame.maxY == anchorFrame.minY - HistoryWindowPlacementResolver.menuBarGap)
    }

    @Test("Menu bar anchor is clamped inside the visible screen")
    func attachedFrameClampsInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 500, height: 700)
        let anchorFrame = NSRect(x: 480, y: 676, width: 20, height: 24)
        let windowSize = NSSize(width: 460, height: 640)

        let frame = HistoryWindowPlacementResolver.attachedToAnchor(
            anchorFrame: anchorFrame,
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
    }

    @Test("Center placement uses the visible screen midpoint")
    func centerFrameUsesVisibleScreenMidpoint() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_000, height: 800)
        let windowSize = NSSize(width: 460, height: 640)

        let frame = HistoryWindowPlacementResolver.centered(
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.midY == visibleFrame.midY)
    }

    @Test("Top-right placement leaves screen padding")
    func topRightFrameLeavesScreenPadding() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_000, height: 800)
        let windowSize = NSSize(width: 460, height: 640)

        let frame = HistoryWindowPlacementResolver.topRight(
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.maxX == visibleFrame.maxX - HistoryWindowPlacementResolver.screenPadding)
        #expect(frame.maxY == visibleFrame.maxY - HistoryWindowPlacementResolver.screenPadding)
    }

    @Test("Focused input placement opens below the field when there is room")
    func focusedInputPlacementOpensBelowFieldWhenThereIsRoom() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let inputFrame = NSRect(x: 320, y: 700, width: 360, height: 32)
        let windowSize = NSSize(width: 392, height: 430)

        let frame = HistoryWindowPlacementResolver.attachedToFocusedInput(
            inputFrame: inputFrame,
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.minX == inputFrame.minX)
        #expect(frame.maxY == inputFrame.minY - HistoryWindowPlacementResolver.inputGap)
    }

    @Test("Focused input placement flips above the field near the bottom edge")
    func focusedInputPlacementFlipsAboveFieldNearBottomEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let inputFrame = NSRect(x: 320, y: 80, width: 360, height: 32)
        let windowSize = NSSize(width: 392, height: 430)

        let frame = HistoryWindowPlacementResolver.attachedToFocusedInput(
            inputFrame: inputFrame,
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.minY == inputFrame.maxY + HistoryWindowPlacementResolver.inputGap)
    }

    @Test("Focused caret placement centers around narrow input bounds")
    func focusedCaretPlacementCentersAroundNarrowInputBounds() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let caretFrame = NSRect(x: 700, y: 700, width: 1, height: 20)
        let windowSize = NSSize(width: 392, height: 430)

        let frame = HistoryWindowPlacementResolver.attachedToFocusedInput(
            inputFrame: caretFrame,
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.midX == caretFrame.midX)
    }

    @Test("Close does not persist a user frame")
    func closeDoesNotPersistUserFrame() {
        #expect(!HistoryWindowFramePersistencePolicy.shouldPersistFrame(
            for: .close,
            isApplyingProgrammaticFrame: false,
            isWindowVisible: true
        ))
    }

    @Test("User move and resize persist only outside programmatic placement")
    func userMoveAndResizePersistOutsideProgrammaticPlacement() {
        #expect(HistoryWindowFramePersistencePolicy.shouldPersistFrame(
            for: .userMove,
            isApplyingProgrammaticFrame: false,
            isWindowVisible: true
        ))
        #expect(HistoryWindowFramePersistencePolicy.shouldPersistFrame(
            for: .userResize,
            isApplyingProgrammaticFrame: false,
            isWindowVisible: true
        ))
        #expect(!HistoryWindowFramePersistencePolicy.shouldPersistFrame(
            for: .userMove,
            isApplyingProgrammaticFrame: true,
            isWindowVisible: true
        ))
        #expect(!HistoryWindowFramePersistencePolicy.shouldPersistFrame(
            for: .userResize,
            isApplyingProgrammaticFrame: false,
            isWindowVisible: false
        ))
    }

    @Test("Missing or invalid placement defaults to menu bar icon")
    func missingOrInvalidPlacementDefaultsToMenuBarIcon() {
        #expect(HistoryWindowPlacementDefaults.initialPlacement(storedRawValue: nil) == .menuBarIcon)
        #expect(HistoryWindowPlacementDefaults.initialPlacement(storedRawValue: "bogus") == .menuBarIcon)
    }

    @Test("Stored placement is honoured")
    func storedPlacementIsHonoured() {
        #expect(HistoryWindowPlacementDefaults.initialPlacement(storedRawValue: "lastPosition") == .lastPosition)
        #expect(HistoryWindowPlacementDefaults.initialPlacement(storedRawValue: "center") == .center)
        #expect(HistoryWindowPlacementDefaults.initialPlacement(storedRawValue: "topRight") == .topRight)
    }

    @Test("Quick picker opens near the focused input by default")
    func quickPickerDefaultsToFocusedInput() {
        #expect(QuickPickerPlacementDefaults.initialPlacement(storedRawValue: nil) == .focusedInput)
        #expect(QuickPickerPlacementDefaults.initialPlacement(storedRawValue: "bogus") == .focusedInput)
        #expect(QuickPickerPlacementDefaults.initialPlacement(storedRawValue: "menuBarIcon") == .menuBarIcon)
        #expect(QuickPickerPlacementDefaults.initialPlacement(storedRawValue: "lastPosition") == .lastPosition)
    }

    @Test("Shortcut opens the quick picker by default")
    func shortcutDefaultsToQuickPicker() {
        #expect(ShortcutOpenTargetDefaults.initialTarget(storedRawValue: nil) == .quickPicker)
        #expect(ShortcutOpenTargetDefaults.initialTarget(storedRawValue: "bogus") == .quickPicker)
        #expect(ShortcutOpenTargetDefaults.initialTarget(storedRawValue: "fullHistory") == .fullHistory)
    }
}
