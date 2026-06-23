import AppKit
import Observation
@preconcurrency import ApplicationServices

@MainActor
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted: Bool

    @ObservationIgnored private var trustObserver: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        isTrusted = AXIsProcessTrusted()

        // A menu-bar accessory does not reliably receive `applicationDidBecomeActive` when the user
        // returns from System Settings, so polling activation isn't enough to notice a grant. The
        // system posts this distributed notification whenever any app's Accessibility authorization
        // changes — observe it so `isTrusted` stays live (it drives the in-app "access needed" hints).
        // The TCC change can land a beat after the notification, so re-check on the next runloop tick.
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.apiChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // Runs on the main actor so it can drop the non-Sendable observer token safely.
    isolated deinit {
        pollTask?.cancel()
        if let trustObserver {
            DistributedNotificationCenter.default().removeObserver(trustObserver)
        }
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Open the Accessibility pane and poll for the grant. The distributed notification can be
    /// missed (and the TCC change can lag the user's toggle), so this is the reliable path: it
    /// re-checks once a second until trust flips or a short budget elapses, then stops. Bounded, so
    /// there's no permanent timer — nothing runs unless the user is actively granting.
    @MainActor
    func openSettingsAndAwaitGrant() {
        Self.openSettings()
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self?.refresh()
                if self?.isTrusted == true { return }
            }
        }
    }

    nonisolated static func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Posted by the system when Accessibility (and related) authorization changes.
    private static let apiChangedNotification = Notification.Name("com.apple.accessibility.api")

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @MainActor
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// User-facing copy shared by the history footer and Settings so the two can't drift apart.
    enum Copy {
        static let accessNeeded = "Accessibility access needed for auto-paste"
        static let openSettings = "Open System Settings"
    }
}
