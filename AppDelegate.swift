import Cocoa
import SwiftUI
import Observation

@MainActor
@Observable
final class AppStatus {
    var hotkeyRegistrationFailed = false
}

/// The composition root. It owns the shared clipboard state, accessibility permission,
/// app status, menu-bar hub, and app-level lifecycle callbacks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsManager.shared
    let axPermission = AccessibilityPermission()
    let appStatus = AppStatus()
    let clipboardStore = ClipboardStore(settings: SettingsManager.shared.captureSettings)

    private var clipboardController: ClipboardController?
    private var hub: HubController?
    private var welcomeWindowController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        clipboardController?.stop()
        clipboardStore.flushPendingWrites()
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
