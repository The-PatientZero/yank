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
    private var didSettleSettings = false

    private init() {
        let appGroup = AppGroupContext.live()
        let store = ClipStore(context: appGroup, deferHistoryLoad: true)
        // Before the first unlock the defaults can read as empty, and the history has not been
        // read yet to tell, so settings must not seed defaults over the values the user chose
        // until `hydrate()` has found the files readable.
        let settings = IOSSettings(defaults: appGroup?.defaults, defaultsMayBeUnreadable: true)
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

    /// Reads the saved history off the main thread, then lets the settings seed what is missing
    /// and marks capture setup complete for an install that already has clips. Does nothing more
    /// while storage waits for the first unlock: `recoverProtectedStorage()` finishes that.
    func hydrate() async {
        await store.hydrate()
        guard !didSettleSettings, !store.isAwaitingFirstUnlock else { return }
        didSettleSettings = true
        settings.reloadAfterDefaultsReadable()
        if !store.items.isEmpty {
            settings.completeCaptureSetup()
        }
    }

    /// After a launch before the first unlock, reads the history and the settings again once
    /// the files can be read. Does nothing when storage was not waiting for that.
    func recoverProtectedStorage() {
        guard store.retryStorageIfUnreadable() else { return }
        didSettleSettings = true
        settings.reloadAfterDefaultsReadable()
        if !store.items.isEmpty {
            settings.completeCaptureSetup()
        }
    }
}
