import Testing
@testable import Yank

@Suite("Yank Panel Tokens")
struct YankPanelTokensTests {
    @Test("Action buttons meet the compact target size")
    func actionButtonsMeetCompactTargetSize() {
        #expect(YankPanelTokens.primaryButtonSize.height >= ControlTarget.compact)
        #expect(YankPanelTokens.secondaryButtonSize.height >= ControlTarget.compact)
        #expect(YankPanelTokens.quietButtonSize.height >= ControlTarget.compact)
    }

    @Test("Permission panel reserves enough room for card content")
    func permissionPanelReservesEnoughRoomForCardContent() {
        #expect(YankPanelTokens.compactToastPanelSize.width >= 320)
        #expect(YankPanelTokens.compactToastPanelSize.height >= 180)
        #expect(YankPanelTokens.contentInset >= Space.lg)
    }
}
