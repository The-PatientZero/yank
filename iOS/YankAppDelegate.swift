import UIKit

/// iOS counterpart to the macOS `AppDelegate`: registers for remote notifications and bridges
/// CloudKit silent pushes into the sync engine for real-time updates. Push *delivery* also needs
/// the Push Notifications capability on the provisioning profile; without it the app still pulls
/// on launch/foreground and on local changes — this just adds the live path.
@MainActor
final class YankAppDelegate: NSObject, UIApplicationDelegate {
    private static let cloudContainerID = "iCloud.com.thepatientzero.yank"
    var remoteChangeHandler: (() async -> Bool)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Self.syncEnabledFromDefaults() && CloudContainerProvisioning.isProvisioned(for: Self.cloudContainerID) {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard Self.syncEnabledFromDefaults() else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            guard let remoteChangeHandler else {
                completionHandler(.noData)
                return
            }
            completionHandler(await remoteChangeHandler() ? .newData : .failed)
        }
    }

    private static func syncEnabledFromDefaults() -> Bool {
        let defaults = UserDefaults(suiteName: ClipStore.appGroup) ?? .standard
        return defaults.object(forKey: SettingsKeys.syncEnabled) as? Bool ?? SettingsDefaults.syncEnabled
    }
}
