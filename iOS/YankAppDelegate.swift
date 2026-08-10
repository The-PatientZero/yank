import UIKit

/// Owns the finite UIKit execution window used to finish an iOS history checkpoint when
/// the scene leaves the active state. The injected begin/end closures keep the lifecycle
/// rules deterministic in tests while the app delegate supplies the real UIKit boundary.
@MainActor
final class IOSHistoryBackgroundFlushCoordinator {
    static let taskName = "Yank history flush"

    typealias BeginBackgroundTask = (
        _ name: String,
        _ expiration: @escaping @MainActor () -> Void
    ) -> (@MainActor () -> Void)?

    private final class Operation {
        let id = UUID()
        var endBackgroundTask: (@MainActor () -> Void)?
        var task: Task<Void, Never>?
        var expired = false
    }

    private var operation: Operation?

    /// Starts one owned flush. Repeated inactive/background callbacks coalesce into the
    /// current operation; after it finishes, a later active → inactive transition may start
    /// a fresh checkpoint.
    @discardableResult
    func flushWhenLeavingActive(
        beginBackgroundTask: BeginBackgroundTask,
        flush: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void = { _ in }
    ) -> Bool {
        guard operation == nil else { return false }

        let operation = Operation()
        self.operation = operation
        guard let endBackgroundTask = beginBackgroundTask(Self.taskName, { [weak self] in
            self?.expire(operation.id)
        }) else {
            self.operation = nil
            return false
        }
        operation.endBackgroundTask = endBackgroundTask

        // Be balanced even if an injected/system boundary expires synchronously while
        // `beginBackgroundTask` is returning.
        guard !operation.expired else {
            finish(operation.id)
            return false
        }

        operation.task = Task { @MainActor [weak self] in
            do {
                try await flush()
            } catch is CancellationError {
                // Expiration owns cancellation and has already closed the UIKit task.
            } catch {
                onFailure(error)
            }
            self?.finish(operation.id)
        }
        return true
    }

    private func expire(_ operationID: UUID) {
        guard let operation, operation.id == operationID else { return }
        operation.expired = true
        operation.task?.cancel()
        if operation.endBackgroundTask != nil {
            finish(operationID)
        }
    }

    private func finish(_ operationID: UUID) {
        guard let operation, operation.id == operationID else { return }
        self.operation = nil
        let endBackgroundTask = operation.endBackgroundTask
        operation.endBackgroundTask = nil
        endBackgroundTask?()
    }
}

/// iOS counterpart to the macOS `AppDelegate`: registers for remote notifications and bridges
/// CloudKit silent pushes into the sync engine for real-time updates. Push *delivery* also needs
/// the Push Notifications capability on the provisioning profile; without it the app still pulls
/// on launch/foreground and on local changes — this just adds the live path.
@MainActor
final class YankAppDelegate: NSObject, UIApplicationDelegate {
    private static let cloudContainerID = "iCloud.com.thepatientzero.yank"
    private let syncEnabledProvider: @MainActor () -> Bool
    private let historyFlushCoordinator = IOSHistoryBackgroundFlushCoordinator()
    /// Wired by the scene once the sync controller exists. A silent push can land before that
    /// happens (launch straight into a background fetch), so assigning the handler drains the
    /// latch below instead of losing that notification until the next trigger.
    var remoteChangeHandler: (() async -> Bool)? {
        didSet { drainMissedRemoteChange() }
    }
    private var pendingRemoteChange: PendingRemoteChange?
    private var missedRemoteChangeWhileUnwired = false

    private struct PendingRemoteChange {
        let id: UUID
        let task: Task<Void, Never>
        let completion: (UIBackgroundFetchResult) -> Void
    }

    override init() {
        self.syncEnabledProvider = Self.syncEnabledFromDefaults
        super.init()
    }

    init(syncEnabledProvider: @escaping @MainActor () -> Bool) {
        self.syncEnabledProvider = syncEnabledProvider
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if syncEnabledProvider()
            && CloudContainerProvisioning.isProvisioned(for: Self.cloudContainerID) {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        cancelPendingRemoteChange()
        guard syncEnabledProvider() else {
            completionHandler(.noData)
            return
        }
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(.noData)
                return
            }
            guard !Task.isCancelled,
                  self.syncEnabledProvider(),
                  self.pendingRemoteChange?.id == requestID else {
                self.finishRemoteChange(requestID, result: .noData)
                return
            }
            guard let remoteChangeHandler else {
                // Report immediately — iOS expects the completion handler promptly — and remember
                // that a remote change is still unapplied.
                self.missedRemoteChangeWhileUnwired = true
                self.finishRemoteChange(requestID, result: .noData)
                return
            }
            let changed = await remoteChangeHandler()
            guard !Task.isCancelled,
                  self.syncEnabledProvider(),
                  self.pendingRemoteChange?.id == requestID else {
                self.finishRemoteChange(requestID, result: .noData)
                return
            }
            self.finishRemoteChange(requestID, result: changed ? .newData : .failed)
        }
        pendingRemoteChange = PendingRemoteChange(
            id: requestID,
            task: task,
            completion: completionHandler
        )
    }

    func disableRemoteChanges() {
        cancelPendingRemoteChange()
    }

    func flushHistoryWhenLeavingActive(
        _ flush: @escaping @MainActor () async throws -> Void
    ) {
        historyFlushCoordinator.flushWhenLeavingActive(
            beginBackgroundTask: { name, expiration in
                let identifier = UIApplication.shared.beginBackgroundTask(
                    withName: name,
                    expirationHandler: expiration
                )
                guard identifier != .invalid else { return nil }
                return {
                    UIApplication.shared.endBackgroundTask(identifier)
                }
            },
            flush: flush,
            onFailure: { error in
                clipStoreLog.error(
                    "Failed to flush iOS history before suspension: \(error.localizedDescription)"
                )
            }
        )
    }

    /// Runs exactly one catch-up refresh for a push that arrived before the handler existed.
    private func drainMissedRemoteChange() {
        guard missedRemoteChangeWhileUnwired, let remoteChangeHandler else { return }
        missedRemoteChangeWhileUnwired = false
        Task { @MainActor [weak self] in
            guard let self, self.syncEnabledProvider() else { return }
            _ = await remoteChangeHandler()
        }
    }

    private func cancelPendingRemoteChange() {
        guard let pendingRemoteChange else { return }
        self.pendingRemoteChange = nil
        pendingRemoteChange.task.cancel()
        pendingRemoteChange.completion(.noData)
    }

    private func finishRemoteChange(
        _ requestID: UUID,
        result: UIBackgroundFetchResult
    ) {
        guard let pendingRemoteChange, pendingRemoteChange.id == requestID else { return }
        self.pendingRemoteChange = nil
        pendingRemoteChange.completion(result)
    }

    private static func syncEnabledFromDefaults() -> Bool {
        guard let defaults = AppGroupContext.live()?.defaults else { return false }
        return defaults.object(forKey: SettingsKeys.syncEnabled) as? Bool ?? SettingsDefaults.syncEnabled
    }
}
