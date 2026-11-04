import AppKit

/// Opens System Settings at the Apple ID pane, where the iCloud account and its storage live.
/// The pane identifier is not formally documented; an unknown one still opens System Settings.
enum SyncSystemSettings {
    private static let appleIDPaneURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!

    @MainActor
    static func openAppleIDPane() {
        NSWorkspace.shared.open(appleIDPaneURL)
    }
}
