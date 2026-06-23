import SwiftUI
import CloudKit

@main
struct YankApp: App {
    private static let containerID = "iCloud.com.thepatientzero.yank"

    @UIApplicationDelegateAdaptor(YankAppDelegate.self) private var appDelegate
    @State private var store = ClipStore()
    @State private var settings = IOSSettings()
    @State private var cloudContainer: CKContainer?
    @State private var sync: CloudKitSyncService?
    @State private var iCloudSignedOut = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _cloudContainer = State(initialValue: Self.syncEnabledFromDefaults() ? Self.makeCloudContainer() : nil)
    }

    private var spotlightEnabled: Bool {
        (UserDefaults(suiteName: ClipStore.appGroup) ?? .standard).bool(forKey: SettingsKeys.spotlightIndexing)
    }

    var body: some Scene {
        WindowGroup {
            HistoryView(
                store: store,
                settings: settings,
                iCloudSignedOut: iCloudSignedOut,
                onRetrySync: { await startSync(force: true) }
            )
                .tint(settings.theme.foreground)
                .task {
                    appDelegate.remoteChangeHandler = { await handleRemoteChange() }
                    store.enforceRetentionAndLimit()
                    await checkAccountAndStartSync()
                    if spotlightEnabled { SpotlightIndexer.index(store.items) }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await checkAccountAndStartSync() }
                    }
                }
                .onChange(of: settings.syncEnabled) { _, enabled in
                    if enabled {
                        Task { await checkAccountAndStartSync() }
                    } else {
                        stopSync()
                    }
                }
                .onChange(of: store.items.count) {
                    if spotlightEnabled { SpotlightIndexer.schedule(store.items) }
                }
        }
    }

    private func checkAccountAndStartSync() async {
        guard settings.syncEnabled else {
            stopSync()
            return
        }
        if cloudContainer == nil {
            cloudContainer = Self.makeCloudContainer()
        }
        guard let container = cloudContainer else {
            store.markSyncUnavailable(reason: .notProvisioned)
            return
        }
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                iCloudSignedOut = false
                UIApplication.shared.registerForRemoteNotifications()
                await startSync()
            case .noAccount, .restricted, .temporarilyUnavailable:
                iCloudSignedOut = true
                store.markSyncUnavailable(reason: .notAuthenticated)
            case .couldNotDetermine:
                iCloudSignedOut = false
                store.markSyncFailed("Could not determine iCloud account status")
            @unknown default:
                iCloudSignedOut = false
                await startSync()
            }
        } catch {
            store.markSyncFailed(error.localizedDescription)
        }
    }

    private func startSync(force: Bool = false) async {
        guard settings.syncEnabled else {
            stopSync()
            return
        }
        guard let cloudContainer else { return }
        guard sync == nil || force else { return }
        let service = sync ?? CloudKitSyncService(
            containerIdentifier: Self.containerID,
            store: store,
            database: cloudContainer.privateCloudDatabase
        )
        sync = service
        switch await service.start() {
        case .started:
            break
        case .failed(let message):
            store.markSyncFailed(message)
        }
    }

    private func handleRemoteChange() async -> Bool {
        guard settings.syncEnabled else { return false }
        if sync == nil {
            await checkAccountAndStartSync()
        }
        guard let sync else { return false }
        return await sync.handleRemoteChange()
    }

    private func stopSync() {
        sync = nil
        cloudContainer = nil
        UIApplication.shared.unregisterForRemoteNotifications()
        store.markSyncUnavailable(reason: .disabled)
    }

    private static func makeCloudContainer() -> CKContainer? {
        guard syncEnabledFromDefaults() else { return nil }
        guard CloudContainerProvisioning.isProvisioned(for: containerID) else { return nil }
        return CKContainer(identifier: containerID)
    }

    private static func syncEnabledFromDefaults() -> Bool {
        let defaults = UserDefaults(suiteName: ClipStore.appGroup) ?? .standard
        return defaults.object(forKey: SettingsKeys.syncEnabled) as? Bool ?? SettingsDefaults.syncEnabled
    }
}
