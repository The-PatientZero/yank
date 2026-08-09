import Foundation
import Testing
@testable import YankiOS

@Suite("iOS Settings")
@MainActor
struct IOSSettingsTests {
    @Test("Missing App Group defaults is surfaced without a standard-defaults fallback")
    func missingSharedDefaultsFailsClosed() {
        let settings = IOSSettings(defaults: nil)

        #expect(settings.storageUnavailable)
        #expect(!settings.syncEnabled)
        #expect(!settings.spotlightIndexing)
        #expect(settings.foregroundCaptureMode == .undecided)
        #expect(!settings.setForegroundCaptureMode(.automatic))
        #expect(!settings.setForegroundCaptureMode(.explicitOnly))
        #expect(settings.foregroundCaptureMode == .undecided)
    }

    @Test("iCloud sync defaults off and persists explicit opt-in")
    func syncDefaultsOffAndPersistsOptIn() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = IOSSettings(defaults: defaults)
        #expect(!initial.syncEnabled)
        #expect(defaults.bool(forKey: SettingsKeys.syncEnabled) == false)

        initial.syncEnabled = true
        let reloaded = IOSSettings(defaults: defaults)
        #expect(reloaded.syncEnabled)
    }

    @Test("Seeds shared defaults for extensions")
    func seedsSharedDefaultsForExtensions() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = IOSSettings(defaults: defaults)

        #expect(defaults.integer(forKey: SettingsKeys.historyLimit) == settings.historyLimit.rawValue)
        #expect(defaults.object(forKey: SettingsKeys.retentionDays) != nil)
        #expect(defaults.string(forKey: SettingsKeys.themeID) == settings.themeID)
        #expect(defaults.string(forKey: SettingsKeys.viewMode) == settings.viewMode.rawValue)
        #expect(defaults.string(forKey: SettingsKeys.density) == settings.density.rawValue)
        #expect(defaults.object(forKey: SettingsKeys.syncEnabled) != nil)
        #expect(defaults.object(forKey: SettingsKeys.spotlightIndexing) != nil)
        #expect(defaults.object(forKey: IOSSettings.foregroundCaptureModeKey) == nil)
    }

    @Test("Foreground capture mode requires a valid persisted user choice")
    func foregroundCaptureModePersistenceAndInvalidFallback() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = IOSSettings(defaults: defaults)
        #expect(initial.foregroundCaptureMode == .undecided)
        #expect(defaults.object(forKey: IOSSettings.foregroundCaptureModeKey) == nil)

        #expect(initial.setForegroundCaptureMode(.automatic))
        #expect(
            defaults.string(forKey: IOSSettings.foregroundCaptureModeKey)
                == IOSForegroundCaptureMode.automatic.rawValue
        )
        #expect(IOSSettings(defaults: defaults).foregroundCaptureMode == .automatic)

        #expect(initial.setForegroundCaptureMode(.explicitOnly))
        #expect(IOSSettings(defaults: defaults).foregroundCaptureMode == .explicitOnly)

        #expect(initial.setForegroundCaptureMode(.undecided))
        #expect(defaults.object(forKey: IOSSettings.foregroundCaptureModeKey) == nil)
        #expect(IOSSettings(defaults: defaults).foregroundCaptureMode == .undecided)

        defaults.set("future-or-corrupt-value", forKey: IOSSettings.foregroundCaptureModeKey)
        #expect(IOSSettings(defaults: defaults).foregroundCaptureMode == .undecided)
    }

    @Test("Capture-choice presentation and session deferral are mode-gated")
    func foregroundCapturePresentation() {
        #expect(
            IOSForegroundCaptureMode.decisionChoices == [.automatic, .explicitOnly]
        )
        #expect(
            IOSForegroundCaptureMode.settingsChoices
                == [.undecided, .automatic, .explicitOnly]
        )
        #expect(IOSForegroundCaptureMode.undecided.choiceTitle == "Ask Next Time")
        #expect(
            IOSForegroundCaptureMode.automatic.choiceTitle == "Check When Yank Opens"
        )
        #expect(
            IOSForegroundCaptureMode.explicitOnly.choiceTitle
                == "Only When I Ask"
        )
        #expect(
            IOSForegroundCaptureMode.automatic.choiceDescription
                .contains("becomes active")
        )
        #expect(
            IOSForegroundCaptureMode.explicitOnly.choiceDescription
                .contains("keyboard remains read-only")
        )
        var session = IOSForegroundCaptureDisclosureSession()
        #expect(session.presentation(for: .undecided) == .prompt)
        #expect(session.presentation(for: .automatic) == .hidden)
        #expect(session.presentation(for: .explicitOnly) == .hidden)

        session.deferForCurrentSession()
        #expect(session.presentation(for: .undecided) == .hidden)
        #expect(
            IOSForegroundCaptureDisclosureSession().presentation(for: .undecided)
                == .prompt
        )
    }

    @Test("Appearance and retention choices persist")
    func appearanceAndRetentionChoicesPersist() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = IOSSettings(defaults: defaults)
        settings.themeID = "mint"
        settings.viewMode = .grid
        settings.density = .snug
        settings.setHistoryLimit(.deep)
        settings.retentionDays = 30
        settings.spotlightIndexing = true

        let reloaded = IOSSettings(defaults: defaults)
        #expect(reloaded.themeID == "mint")
        #expect(reloaded.viewMode == .grid)
        #expect(reloaded.density == .snug)
        #expect(reloaded.historyLimit == .deep)
        #expect(reloaded.retentionDays == 30)
        #expect(reloaded.spotlightIndexing)
    }

    @Test("A user-chosen history limit is stamped; an adopted one keeps the remote stamp")
    func historyLimitStampDistinguishesChosenFromAdopted() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = IOSSettings(defaults: defaults)
        // Never chosen on this device, so any device that has made a real choice outranks it.
        #expect(settings.historyLimitUpdatedAt == .distantPast)

        let beforeChoice = Date()
        settings.setHistoryLimit(.deep)
        #expect(settings.historyLimitUpdatedAt >= beforeChoice)

        let remoteStamp = Date(timeIntervalSinceReferenceDate: 5_000)
        settings.adoptHistoryLimit(
            SyncedSettings(historyLimit: .unlimited, updatedAt: remoteStamp)
        )
        #expect(settings.historyLimit == .unlimited)
        // Verbatim, not re-stamped: otherwise this device would look like the newest writer and
        // bounce the value back at the device it came from.
        #expect(settings.historyLimitUpdatedAt == remoteStamp)

        let reloaded = IOSSettings(defaults: defaults)
        #expect(reloaded.historyLimit == .unlimited)
        #expect(reloaded.historyLimitUpdatedAt == remoteStamp)
    }

    @Test("Capture methods persist independently and completing all three closes setup")
    func captureMethodsPersistIndependently() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = IOSSettings(defaults: defaults)
        #expect(settings.confirmedCaptureMethods.isEmpty)
        #expect(!settings.captureSetupCompleted)

        settings.setCaptureMethod(.keyboard, confirmed: true)
        #expect(settings.confirmedCaptureMethods == [.keyboard])
        #expect(!settings.captureSetupCompleted)

        let reloaded = IOSSettings(defaults: defaults)
        #expect(reloaded.confirmedCaptureMethods == [.keyboard])
        #expect(!reloaded.captureSetupCompleted)

        reloaded.setCaptureMethod(.shareSheet, confirmed: true)
        reloaded.setCaptureMethod(.shortcut, confirmed: true)
        #expect(reloaded.confirmedCaptureMethods == Set(IOSCaptureMethod.allCases))
        #expect(reloaded.captureSetupCompleted)
        #expect(IOSSettings(defaults: defaults).captureSetupCompleted)
    }

    @Test("Capture setup names a zero-method completion as a deferral")
    func captureSetupCompletionTitleMatchesSelection() {
        #expect(
            CaptureSetupCopy.completionActionTitle(confirmedMethodCount: 0)
                == "Skip for Now"
        )
        #expect(
            CaptureSetupCopy.completionActionTitle(confirmedMethodCount: 1)
                == "Continue"
        )
    }

    @Test("Successful capture evidence confirms only the methods that were used")
    func captureEvidenceConfirmsUsedMethods() throws {
        let suiteName = "IOSSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = IOSSettings(defaults: defaults)

        settings.recordSuccessfulCaptureMethods(from: ["Share", "Shortcuts"])

        #expect(settings.confirmedCaptureMethods == [.shareSheet, .shortcut])
        #expect(!settings.confirmedCaptureMethods.contains(.keyboard))
        #expect(settings.captureSetupCompleted)
    }

    @Test("Empty-history presentation advances independently of clip count")
    func emptyHistoryPresentationUsesCaptureSetupCompletion() {
        let setup = HistoryEmptyPresentation.resolve(
            iCloudSignedOut: false,
            syncFailureMessage: nil,
            isAwaitingFirstSync: false,
            captureSetupCompleted: false
        )
        let ready = HistoryEmptyPresentation.resolve(
            iCloudSignedOut: false,
            syncFailureMessage: nil,
            isAwaitingFirstSync: false,
            captureSetupCompleted: true
        )

        #expect(setup == .captureSetup)
        #expect(ready == .ready)
    }

    @Test("Sync and account failures keep precedence over capture setup")
    func emptyHistoryPresentationPreservesSyncPrecedence() {
        #expect(HistoryEmptyPresentation.resolve(
            iCloudSignedOut: true,
            syncFailureMessage: "failed",
            isAwaitingFirstSync: true,
            captureSetupCompleted: true
        ) == .iCloudSignedOut)
        #expect(HistoryEmptyPresentation.resolve(
            iCloudSignedOut: false,
            syncFailureMessage: "failed",
            isAwaitingFirstSync: true,
            captureSetupCompleted: true
        ) == .syncFailed("failed"))
        #expect(HistoryEmptyPresentation.resolve(
            iCloudSignedOut: false,
            syncFailureMessage: nil,
            isAwaitingFirstSync: true,
            captureSetupCompleted: true
        ) == .syncing)
    }
}
