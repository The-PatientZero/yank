import Foundation
import Testing
@testable import YankCore

@Suite struct UpdateLifecycleTests {
    @Test func idlePresentsInlineCheckAction() {
        let presentation = UpdateLifecycleState.idle.menuPresentation

        #expect(presentation.title == "Check for updates")
        #expect(presentation.action == .check)
        #expect(!presentation.isWorking)
    }

    @Test func checkingDisablesRepeatedChecks() {
        let presentation = UpdateLifecycleState.checking.menuPresentation

        #expect(presentation.title == "Checking for updates")
        #expect(presentation.isWorking)
        #expect(presentation.action == nil)
    }

    @Test func availableUpdatePresentsInstallRow() {
        let presentation = UpdateLifecycleState.available(version: "1.2.3", tag: "v1.2.3").menuPresentation

        #expect(presentation.title == "Install 1.2.3")
        #expect(presentation.trailing.isEmpty)
        #expect(presentation.isActive)
        #expect(presentation.action == .install)
    }

    @Test func stagedUpdatePresentsRelaunchRow() {
        let staged = StagedUpdate(
            version: "1.2.3",
            tag: "v1.2.3",
            stagedAppPath: "/tmp/Yank.app",
            targetAppPath: "/Applications/Yank.app",
            stagedAt: Date(timeIntervalSince1970: 0)
        )

        let presentation = UpdateLifecycleState.staged(staged).menuPresentation

        #expect(presentation.title == "Relaunch 1.2.3")
        #expect(presentation.trailing.isEmpty)
        #expect(presentation.isActive)
        #expect(presentation.action == .relaunch)
    }

    @Test func failurePresentsRetryRow() {
        let failure = UpdateFailureContext(
            title: "Could not check for updates",
            detail: "The Internet connection appears to be offline.",
            version: nil,
            tag: nil
        )

        let presentation = UpdateLifecycleState.failed(failure).menuPresentation

        #expect(presentation.title == "Retry update check")
        #expect(presentation.trailing == "Failed")
        #expect(presentation.action == .retry)
    }

    @Test func upToDateAllowsAnotherManualCheck() {
        let presentation = UpdateLifecycleState.upToDate(version: "1.2.3").menuPresentation

        #expect(presentation.title == "Check again")
        #expect(presentation.trailing == "Current")
        #expect(presentation.action == .check)
    }

    @Test func installedUpdatePresentsInlineWhatsNewRow() {
        let presentation = UpdateLifecycleState.installed(
            version: "1.2.3",
            tag: "v1.2.3",
            releaseNotes: """
            ## What's Changed
            - Inline update notes
            - Cleaner updater lifecycle
            **Full Changelog**: https://github.com/The-PatientZero/yank/compare/v1.2.2...v1.2.3
            """,
            releaseURL: "https://github.com/The-PatientZero/yank/releases/tag/v1.2.3"
        ).menuPresentation

        #expect(presentation.title == "What's new in 1.2.3")
        #expect(presentation.trailing == "Open")
        #expect(presentation.detail == "Inline update notes\nCleaner updater lifecycle")
        #expect(presentation.action == .openReleaseNotes)
        #expect(presentation.accessibilityHint == "Opens release notes on GitHub.")
    }

    @Test func installedUpdateFallsBackWhenGeneratedNotesOnlyHaveAChangelog() {
        let presentation = UpdateLifecycleState.installed(
            version: "1.2.3",
            tag: "v1.2.3",
            releaseNotes: "**Full Changelog**: https://github.com/The-PatientZero/yank/compare/v1.2.2...v1.2.3",
            releaseURL: "https://github.com/The-PatientZero/yank/releases/tag/v1.2.3"
        ).menuPresentation

        #expect(presentation.detail == "Release notes are available on GitHub.")
        #expect(presentation.action == .openReleaseNotes)
    }

    @Test func installedUpdateDoesNotOpenUntrustedReleasePage() {
        let presentation = UpdateLifecycleState.installed(
            version: "1.2.3",
            tag: "v1.2.3",
            releaseNotes: nil,
            releaseURL: "https://example.com/yank/releases/tag/v1.2.3"
        ).menuPresentation

        #expect(presentation.trailing == "1.2.3")
        #expect(presentation.detail == "Yank 1.2.3 is installed.")
        #expect(presentation.action == .check)
    }

    @Test func onlyMatchingActiveDownloadAcceptsACompletedPayload() {
        let staged = StagedUpdate(
            version: "1.2.3",
            tag: "v1.2.3",
            stagedAppPath: "/tmp/Yank.app",
            targetAppPath: "/Applications/Yank.app",
            stagedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(UpdateLifecycleState.downloading(version: "1.2.3").canAcceptDownloadedUpdate(version: "1.2.3"))
        #expect(!UpdateLifecycleState.downloading(version: "1.2.3").canAcceptDownloadedUpdate(version: "1.2.4"))
        #expect(!UpdateLifecycleState.idle.canAcceptDownloadedUpdate(version: "1.2.3"))
        #expect(!UpdateLifecycleState.checking.canAcceptDownloadedUpdate(version: "1.2.3"))
        #expect(!UpdateLifecycleState.available(version: "1.2.3", tag: "v1.2.3")
            .canAcceptDownloadedUpdate(version: "1.2.3"))
        #expect(!UpdateLifecycleState.staged(staged).canAcceptDownloadedUpdate(version: "1.2.3"))
    }
}
