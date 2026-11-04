import CloudKit
import Foundation
import Network

/// Tells the apps when sync should try again on its own: the network came back, or the iCloud
/// account changed. Both apps use the same policy and run their own recovery when it fires.
///
/// Each kind of event waits `recoverySettlingDelay` after the latest event of its kind, so a
/// burst of changes causes one run. The settling timers are plain tasks and may be cut short
/// when iOS suspends a background-launched process; nothing may rely on them there.
@MainActor
final class SyncRecoveryTriggers {
    /// How long events settle before a recovery runs.
    static let recoverySettlingDelay: Duration = .seconds(2)

    private let settlingDelay: Duration
    private let onNetworkRestored: @MainActor () -> Void
    private let onAccountChanged: @MainActor () -> Void
    /// Keeps a container in existence so account-changed notifications are delivered even while
    /// no sync service exists.
    private let container: CKContainer
    private var monitor: NWPathMonitor?
    /// Bumped on every start and stop, so a callback from a cancelled monitor is ignored.
    private var monitorGeneration: UInt64 = 0
    /// Whether the last path update was satisfied; `nil` until the first update, which is only
    /// the starting state.
    private var lastPathSatisfied: Bool?
    private var accountObserver: NSObjectProtocol?
    private var networkSettling: Task<Void, Never>?
    private var accountSettling: Task<Void, Never>?

    init(
        container: CKContainer,
        settlingDelay: Duration = SyncRecoveryTriggers.recoverySettlingDelay,
        onNetworkRestored: @escaping @MainActor () -> Void,
        onAccountChanged: @escaping @MainActor () -> Void
    ) {
        self.container = container
        self.settlingDelay = settlingDelay
        self.onNetworkRestored = onNetworkRestored
        self.onAccountChanged = onAccountChanged
    }

    isolated deinit {
        stop()
    }

    /// Starts watching. Does nothing when already watching.
    func start() {
        guard monitor == nil else { return }
        monitorGeneration &+= 1
        let generation = monitorGeneration
        lastPathSatisfied = nil
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.pathDidUpdate(satisfied: satisfied, monitorGeneration: generation)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.thepatientzero.yank.sync-recovery.network"))
        self.monitor = monitor
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.accountDidChange()
            }
        }
    }

    /// Stops watching and drops any pending run. Does nothing when already stopped.
    func stop() {
        monitorGeneration &+= 1
        monitor?.cancel()
        monitor = nil
        lastPathSatisfied = nil
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
            self.accountObserver = nil
        }
        networkSettling?.cancel()
        networkSettling = nil
        accountSettling?.cancel()
        accountSettling = nil
    }

    private func pathDidUpdate(satisfied: Bool, monitorGeneration generation: UInt64) {
        guard generation == monitorGeneration else { return }
        let wasSatisfied = lastPathSatisfied
        lastPathSatisfied = satisfied
        // The first update is the starting state, and a switch between two satisfied paths
        // (Wi-Fi to cellular) never lost the connection.
        guard let wasSatisfied, !wasSatisfied, satisfied else { return }
        networkSettling = settle(replacing: networkSettling, run: onNetworkRestored)
    }

    private func accountDidChange() {
        guard accountObserver != nil else { return }
        accountSettling = settle(replacing: accountSettling, run: onAccountChanged)
    }

    private func settle(
        replacing pending: Task<Void, Never>?,
        run action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        pending?.cancel()
        let delay = settlingDelay
        return Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Superseded by a newer event or stopped: only cancellation ends the sleep early.
                return
            }
            action()
        }
    }
}
