import SwiftUI

@main
struct YankApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                store: appDelegate.clipboardStore,
                axPermission: appDelegate.axPermission,
                appStatus: appDelegate.appStatus
            )
        }
    }
}
