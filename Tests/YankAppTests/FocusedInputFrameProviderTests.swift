import AppKit
import Testing
@testable import Yank

@Suite("Focused Input Frame Provider")
struct FocusedInputFrameProviderTests {
    @Test("Converts AX top-left coordinates into AppKit coordinates")
    func convertsAXTopLeftCoordinatesIntoAppKitCoordinates() {
        let axRect = NSRect(x: 120, y: 200, width: 360, height: 24)
        let mainScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        let frame = FocusedInputFrameProvider.appKitRect(
            fromTopLeftScreenRect: axRect,
            mainScreenFrame: mainScreen
        )

        #expect(frame.origin.x == axRect.origin.x)
        #expect(frame.origin.y == 676)
        #expect(frame.size == axRect.size)
    }

    @Test("Keeps AX coordinates usable for displays above the main screen")
    func convertsAXCoordinatesForDisplayAboveMainScreen() {
        let axRect = NSRect(x: 220, y: -760, width: 280, height: 24)
        let mainScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        let frame = FocusedInputFrameProvider.appKitRect(
            fromTopLeftScreenRect: axRect,
            mainScreenFrame: mainScreen
        )

        #expect(frame.origin.y == 1_636)
    }

    @Test("Leaves frame unchanged when main screen geometry is unavailable")
    func leavesFrameUnchangedWithoutMainScreenGeometry() {
        let axRect = NSRect(x: 120, y: 200, width: 360, height: 24)

        let frame = FocusedInputFrameProvider.appKitRect(
            fromTopLeftScreenRect: axRect,
            mainScreenFrame: nil
        )

        #expect(frame == axRect)
    }
}
