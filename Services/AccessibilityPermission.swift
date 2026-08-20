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

        // Menu-bar accessories don't reliably get `applicationDidBecomeActive` on return from System
        // Settings, so this distributed notification is the reliable signal for an Accessibility
        // grant. TCC can lag it by a beat — `refresh()` re-checks on the next runloop tick.
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

    /// Opens the Accessibility pane and polls for the grant — the distributed notification can be
    /// missed, so this is the reliable fallback. Re-checks once a second for up to 60s, then stops;
    /// no permanent timer runs unless the user is actively granting.
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
