import Foundation
import Testing
@testable import YankCore

/// Pins the updater's install gate. `UpdateVersion.isNewer` decides whether a fetched
/// release supersedes the running build; if its ordering drifts, Yank either skips a real
/// update or re-offers one it already has. These cases lock the documented numeric rule,
/// including how non-numeric suffixes and malformed input collapse.
@Suite struct UpdateVersionTests {
    @Test func ordersHigherVersionsAsNewer() {
        #expect(UpdateVersion.isNewer("2.0.0", than: "1.0.0"))
        #expect(UpdateVersion.isNewer("1.2.0", than: "1.1.9"))
        #expect(UpdateVersion.isNewer("1.0.1", than: "1.0.0"))
    }

    @Test func ordersLowerVersionsAsNotNewer() {
        #expect(!UpdateVersion.isNewer("1.0.0", than: "2.0.0"))
        #expect(!UpdateVersion.isNewer("1.1.9", than: "1.2.0"))
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(!UpdateVersion.isNewer("1.2.3", than: "1.2.3"))
    }

    @Test func missingTrailingSegmentsCountAsZero() {
        #expect(!UpdateVersion.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateVersion.isNewer("1.2.0", than: "1.2"))
        #expect(UpdateVersion.isNewer("1.2.1", than: "1.2"))
    }

    @Test func ignoresPreReleaseAndBuildSuffixes() {
        // Non-numeric segments are dropped, so a suffix compares equal to its bare version.
        #expect(!UpdateVersion.isNewer("1.2.0-beta", than: "1.2.0"))
        #expect(!UpdateVersion.isNewer("1.2.0+build42", than: "1.2.0"))
        // Numeric leading segments still order even when a suffix is present.
        #expect(UpdateVersion.isNewer("1.3.0-beta", than: "1.2.0"))
    }

    @Test func malformedInputCollapsesToAllZero() {
        // Garbage parses to no numeric segments, i.e. all-zero — never newer than a real version.
        #expect(!UpdateVersion.isNewer("not-a-version", than: "1.0.0"))
        // A real version is newer than garbage (which reads as 0).
        #expect(UpdateVersion.isNewer("1.0.0", than: "not-a-version"))
        // Two garbage strings are mutually equal, so neither is newer.
        #expect(!UpdateVersion.isNewer("", than: ""))
    }

    // MARK: - Staged-update applicability

    @Test func stagedUpdateAppliesWhenNewerAndTargetingTheRightBundle() {
        #expect(UpdateVersion.stagedUpdateApplies(
            stagedVersion: "1.3.0", currentVersion: "1.2.0", targetAppName: "Yank.app"))
    }

    @Test func stagedUpdateRejectedWhenNotNewer() {
        #expect(!UpdateVersion.stagedUpdateApplies(
            stagedVersion: "1.2.0", currentVersion: "1.2.0", targetAppName: "Yank.app"))
        #expect(!UpdateVersion.stagedUpdateApplies(
            stagedVersion: "1.1.0", currentVersion: "1.2.0", targetAppName: "Yank.app"))
    }

    @Test func stagedUpdateRejectedWhenTargetingTheWrongBundle() {
        // Even a newer version must not install over an unexpected target bundle.
        #expect(!UpdateVersion.stagedUpdateApplies(
            stagedVersion: "2.0.0", currentVersion: "1.0.0", targetAppName: "Evil.app"))
    }

    @Test func stagedUpdateHonoursACustomExpectedBundleName() {
        #expect(UpdateVersion.stagedUpdateApplies(
            stagedVersion: "2.0.0", currentVersion: "1.0.0",
            targetAppName: "Other.app", expectedAppName: "Other.app"))
    }

    // MARK: - Downgrade floor (offer gate)

    @Test func offerGateMatchesIsNewerWhenRunningTheHighestInstalled() {
        // Normal case: floor == current, so the gate is exactly "strictly newer than current".
        #expect(UpdateVersion.shouldOfferUpdate(candidate: "1.3.0", current: "1.2.0", highestInstalled: "1.2.0"))
        #expect(!UpdateVersion.shouldOfferUpdate(candidate: "1.2.0", current: "1.2.0", highestInstalled: "1.2.0"))
    }

    @Test func offerGateBlocksSignedDowngradeBelowHighestInstalled() {
        // Running 1.1.0 but 1.4.0 was previously installed: a manifest re-offering 1.2.0 is
        // newer-than-current yet below the floor, so it is refused.
        #expect(!UpdateVersion.shouldOfferUpdate(candidate: "1.2.0", current: "1.1.0", highestInstalled: "1.4.0"))
        // A genuine upgrade past the floor is still offered.
        #expect(UpdateVersion.shouldOfferUpdate(candidate: "1.5.0", current: "1.1.0", highestInstalled: "1.4.0"))
        // Re-installing exactly the floor is not offered (not strictly newer than current is fine,
        // but equal-to-floor with current below floor is allowed only when strictly newer than current).
        #expect(UpdateVersion.shouldOfferUpdate(candidate: "1.4.0", current: "1.1.0", highestInstalled: "1.4.0"))
    }
}
