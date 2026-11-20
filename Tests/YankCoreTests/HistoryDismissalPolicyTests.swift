import Testing
@testable import YankCore

@Suite struct HistoryDismissalPolicyTests {
    @Test func outsideClickDismissesByDefault() {
        let policy = HistoryDismissalPolicy(
            keepsHistoryWindowOpen: false,
            settingsScreenIsActive: false
        )

        #expect(policy.shouldDismissOnOutsideClick)
    }

    @Test func keepOpenPreferenceSuppressesOutsideClickDismissal() {
        let policy = HistoryDismissalPolicy(
            keepsHistoryWindowOpen: true,
            settingsScreenIsActive: false
        )

        #expect(!policy.shouldDismissOnOutsideClick)
    }

    @Test func settingsScreenSuppressesOutsideClickDismissal() {
        let policy = HistoryDismissalPolicy(
            keepsHistoryWindowOpen: false,
            settingsScreenIsActive: true
        )

        #expect(!policy.shouldDismissOnOutsideClick)
    }
}
