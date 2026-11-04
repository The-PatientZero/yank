import UIKit

/// The store, settings and sync controller the app runs on, created once per process by whoever
/// needs them first. A background launch for a CloudKit push may never create a window, so the
/// app delegate reaches the sync controller through here instead of through the first scene.
/// Only the app and its delegate use this; tests and previews build their own objects.
@MainActor
final class IOSAppRuntime {
    static let shared = IOSAppRuntime()

    let store: ClipStore
    let settings: IOSSettings
    let syncController: IOSCloudSyncController
    private var protectedDataObserver: NSObjectProtocol?

    private init() {
        let appGroup = AppGroupContext.live()
        let store = ClipStore(context: appGroup)
        // Before the first unlock the defaults can read as empty, so settings must not seed
        // defaults over the values the user chose.
        let settings = IOSSettings(
            defaults: appGroup?.defaults,
            defaultsMayBeUnreadable: store.isAwaitingFirstUnlock
        )
        if !store.items.isEmpty {
            settings.completeCaptureSetup()
        }
        self.store = store
        self.settings = settings
        self.syncController = IOSCloudSyncController(store: store, settings: settings)
        // A bonus: the foreground path calls `recoverProtectedStorage()` too and is the one to rely on.
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverProtectedStorage()
            }
        }
    }

    /// What the app delegate runs for a CloudKit push.
    var remoteChangeHandler: () async -> IOSSyncRunOutcome {
        { [syncController] in await syncController.handleRemoteChange() }
    }

    /// After a launch before the first unlock, reads the history and the settings again once
    /// the files can be read. Does nothing when storage was not waiting for that.
    func recoverProtectedStorage() {
        guard store.retryStorageIfUnreadable() else { return }
        settings.reloadAfterDefaultsReadable()
        if !store.items.isEmpty {
            settings.completeCaptureSetup()
        }
    }
}
