import Cocoa
import SwiftUI
import Observation
import Darwin

@MainActor
@Observable
final class AppStatus {
    var hotkeyRegistrationFailed = false
}

struct CloudKitBackfillCommandOutcome: Equatable {
    let marker: String
    let exitStatus: Int32

    static func prerequisiteFailure(_ reason: String) -> Self {
        failure(reason: reason)
    }

    static func completed(dryRun: Bool, result: CloudKitBackfillResult) -> Self {
        let fields =
            "dryRun=\(dryRun) "
            + "local=\(result.localRecordCount) "
            + "presentBefore=\(result.presentRecordCountBefore) "
            + "missingBefore=\(result.missingRecordCountBefore) "
            + "uploaded=\(result.uploadedRecordCount) "
            + "presentAfter=\(result.presentRecordCountAfter) "
            + "remainingMissing=\(result.remainingMissingRecordCount)"
        if dryRun || result.converged {
            return Self(
                marker: "YANK_CLOUD_BACKFILL_RESULT status=success \(fields)",
                exitStatus: EXIT_SUCCESS
            )
        }
        return Self(
            marker: "YANK_CLOUD_BACKFILL_RESULT status=failure \(fields)",
            exitStatus: EXIT_FAILURE
        )
    }

    static func failed(_ error: any Error) -> Self {
        failure(reason: error.localizedDescription)
    }

    private static func failure(reason: String) -> Self {
        let normalized = reason
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
            .prefix(240)
        return Self(
            marker: "YANK_CLOUD_BACKFILL_FAILURE reason=\(normalized)",
            exitStatus: EXIT_FAILURE
        )
    }
}

/// The composition root. It owns the shared clipboard state, accessibility permission,
/// app status, menu-bar hub, and app-level lifecycle callbacks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let backfillArgument = "--cloudkit-backfill"
    private static let backfillDryRunArgument = "--cloudkit-backfill-dry-run"

    let settings = SettingsManager.shared
    let axPermission = AccessibilityPermission()
    let appStatus = AppStatus()
    let clipboardStore = ClipboardStore(settings: SettingsManager.shared.captureSettings)

    private var clipboardController: ClipboardController?
    private var hub: HubController?
    private var welcomeWindowController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if startCloudKitBackfillCommandIfRequested() {
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let hub = HubController(footer: HubAppFooter(
            updateMenu: { UpdateService.shared.menuPresentation },
            onUpdateAction: { UpdateService.shared.handleMenuAction($0) },
            onRestart: { [weak self] in self?.restartOrFinishUpdate() },
            onQuit: { NSApplication.shared.terminate(nil) }
        ), settings: settings)
        self.hub = hub

        let clipboard = ClipboardController(
            dependencies: ClipboardDependencies(
                store: clipboardStore,
                settings: settings,
                axPermission: axPermission,
                appStatus: appStatus,
                hub: hub,
                hotkeys: HotkeyRegistry()
            )
        )
        clipboardController = clipboard
        clipboard.start()

        UpdateService.shared.checkIfJustUpdated()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            UpdateService.shared.checkOnLaunchIfNeeded()
        }

        if !UserDefaults.standard.bool(forKey: "yankWelcomeSeen") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                self.showWelcomeWindow()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        axPermission.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.terminate(store: clipboardStore, controller: clipboardController)
    }

    /// Commits before tearing down sync so a delete pending its 10s auto-commit still mints a
    /// tombstone and pushes, instead of silently resurrecting on next launch.
    static func terminate(store: ClipboardStore, controller: ClipboardController?) {
        store.commitPendingDeleteIfNeeded()
        controller?.stop()
        store.flushPendingWrites()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        clipboardController?.handleRemoteChange()
    }

    /// Reopening the app (e.g. from Finder) surfaces Settings — the recovery path when the
    /// menu-bar icon is hidden, so the user is never stranded.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !settings.showMenuBarIcon {
            clipboardController?.openSettings()
        }
        return true
    }

    private func showWelcomeWindow() {
        let syncAvailable = CloudContainerProvisioning.isProvisioned(for: ClipboardController.cloudContainerID)
        let controller = WelcomeWindowController(axPermission: axPermission, syncAvailable: syncAvailable, manager: settings)
        controller.showWindow(nil)
        welcomeWindowController = controller
    }

    // MARK: - One-time CloudKit recovery

    private func startCloudKitBackfillCommandIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let dryRun = arguments.contains(Self.backfillDryRunArgument)
        guard dryRun || arguments.contains(Self.backfillArgument) else { return false }

        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            guard settings.syncEnabled else {
                finishBackfillCommand(.prerequisiteFailure("sync-disabled"))
            }
            guard CloudContainerProvisioning.isProvisioned(for: ClipboardController.cloudContainerID) else {
                finishBackfillCommand(.prerequisiteFailure("container-not-provisioned"))
            }

            do {
                let sync = CloudKitSyncService(
                    containerIdentifier: ClipboardController.cloudContainerID,
                    store: clipboardStore
                )
                let result = try await sync.backfillMissingLocalRecords(dryRun: dryRun)
                finishBackfillCommand(.completed(dryRun: dryRun, result: result))
            } catch {
                finishBackfillCommand(.failed(error))
            }
        }
        return true
    }

    private func finishBackfillCommand(_ outcome: CloudKitBackfillCommandOutcome) -> Never {
        Self.writeBackfillOutput(outcome.marker)
        clipboardStore.flushPendingWrites()
        exit(outcome.exitStatus)
    }

    private static func writeBackfillOutput(_ output: String) {
        guard let data = "\(output)\n".data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
        try? FileHandle.standardOutput.synchronize()
    }

    // MARK: - App-global footer actions (wired into the hub footer)

    private static let restartDelaySeconds: TimeInterval = 0.4

    /// Finish a staged update if one is ready, otherwise relaunch the app.
    private func restartOrFinishUpdate() {
        if UpdateService.shared.finishStagedUpdateIfAvailable() { return }
        restart()
    }

    private func restart() {
        let appPath = Bundle.main.bundleURL.path
        let launchScript = "sleep \(Self.restartDelaySeconds); /usr/bin/open \(ShellQuoting.quoted(appPath))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", launchScript]

        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            Log.app.error("Failed to restart Yank: \(error.localizedDescription)")
            showRestartFailure()
        }
    }

    private func showRestartFailure() {
        let alert = NSAlert()
        alert.messageText = "Could Not Restart Yank"
        alert.informativeText = "Quit Yank and open it again from Finder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
