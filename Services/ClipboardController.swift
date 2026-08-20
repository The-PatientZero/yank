import Cocoa
import CloudKit

/// Dependencies owned by the composition root and injected into the clipboard runtime.
@MainActor
struct ClipboardDependencies {
    let store: ClipboardStore
    let settings: SettingsManager
    let axPermission: AccessibilityPermission
    let appStatus: AppStatus
    let hub: HubController
    let hotkeys: HotkeyRegistry
}

/// Owns the clipboard runtime: pasteboard watcher, history window, global shortcut,
/// Spotlight indexing, CloudKit sync, and menu-bar command state.
@MainActor
final class ClipboardController {
    /// The iCloud container the clipboard syncs through. Also read by the composition root to
    /// decide whether to offer sync onboarding.
    static let cloudContainerID = "iCloud.com.thepatientzero.yank"

    private let dependencies: ClipboardDependencies
    private var clipboardWatcher: ClipboardWatcher?
    private var historyWindowController: HistoryWindowController?
    private var quickPickerWindowController: QuickPickerWindowController?
    private var enrichmentService: ClipEnrichmentService?
    private var delayedQuickPickerOpen: DispatchWorkItem?
    private var cloudSync: CloudKitSyncService?
    /// Owned here because the sync service holds it weakly, the same way it holds the store.
    private let settingsSyncBridge: SettingsSyncBridge
    /// Resolves the current iCloud account's identity ahead of constructing a sync service, so
    /// a persisted checkpoint from a previous account can be detected and reset. Seam for tests.
    private let accountIdentityProvider: () async throws -> String
    private var cloudSyncConfigureTask: (id: UUID, task: Task<Void, Never>)?
    private var cloudSyncStartTask: (id: UUID, task: Task<Void, Never>)?
    /// Bounded backoff for a failed `start()` (offline at login, CloudKit throttle). Once
    /// exhausted, recovery falls to the wake/periodic pulls below.
    private let cloudSyncStartRetry = BackoffRetryScheduler(delays: ClipboardController.cloudSyncStartRetryDelays)
    /// Coalesces a CloudKit silent push with the wake/periodic catch-up triggers below into at
    /// most one follow-up pull when they arrive while a pull is already in flight.
    private lazy var remoteChangeTrigger = CoalescingTrigger { [weak self] in
        _ = await self?.pullRemoteChange()
    }
    private var observerTokens: [NSObjectProtocol] = []
    /// `NSWorkspace.shared.notificationCenter` is a distinct center from `NotificationCenter.default`,
    /// so its token is tracked and removed separately from `observerTokens`.
    private var wakeObserverToken: NSObjectProtocol?
    private var periodicRemotePullTask: Task<Void, Never>?
    private var pasteSequenceCoordinator: PasteSequenceCoordinator?

    private static let cloudSyncStartRetryDelays: [Duration] = [.seconds(30), .seconds(120), .seconds(600)]
    /// Backstop re-pull while sync is up, covering a silent push dropped during sleep or
    /// throttled delivery — silent pushes are best-effort, never guaranteed.
    private static let periodicRemotePullInterval: Duration = .seconds(3600)
    private static let accountIdentityDefaultsKey = "cloudkit.accountIdentity.\(cloudContainerID)"

    private var store: ClipboardStore { dependencies.store }

    init(
        dependencies: ClipboardDependencies,
        accountIdentityProvider: @escaping () async throws -> String = {
            try await CKContainer(identifier: ClipboardController.cloudContainerID).userRecordID().recordName
        }
    ) {
        self.dependencies = dependencies
        self.settingsSyncBridge = SettingsSyncBridge(settings: dependencies.settings)
        self.accountIdentityProvider = accountIdentityProvider
    }

    // `isolated deinit` runs cleanup on the main actor (the runtime schedules a hop if the last
    // release lands off-main), so it never traps the way `MainActor.assumeIsolated` would, while
    // still allowing access to the non-Sendable `observerTokens`. It's only a backstop:
    // `stop()` is the normal app-termination path.
    isolated deinit {
        stop()
    }

    func start() {
        let watcher = ClipboardWatcher(store: store, settings: dependencies.settings.captureSettings)
        let pasteSequenceCoordinator = makePasteSequenceCoordinator(for: watcher)
        watcher.startWatching()
        clipboardWatcher = watcher

        // Capture reads a value snapshot, so each preference save re-injects the current settings
        // into both store and watcher. The snapshot is `Equatable`, so unchanged values no-op.
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankCaptureSettingsChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let snapshot = self.dependencies.settings.captureSettings
                    self.store.captureSettings = snapshot
                    self.clipboardWatcher?.captureSettings = snapshot
                }
            }
        )

        // Index clips into system-wide Spotlight only when the user has opted in: clipboard
        // history can hold secrets, so system-wide indexing is off by default.
        if dependencies.settings.spotlightIndexingEnabled {
            SpotlightIndexer.index(store.items)
        }
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankLocalStoreDidChange,
                                                   object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.dependencies.settings.spotlightIndexingEnabled else { return }
                    SpotlightIndexer.schedule(self.store.items)
                }
            }
        )
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankSpotlightIndexingChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.dependencies.settings.spotlightIndexingEnabled {
                        SpotlightIndexer.index(self.store.items)
                    } else {
                        SpotlightIndexer.clear()
                    }
                }
            }
        )
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankSyncPreferenceChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.configureCloudSync()
                }
            }
        )

        configureCloudSync()

        historyWindowController = HistoryWindowController(
            store: store,
            settings: dependencies.settings,
            axPermission: dependencies.axPermission,
            appStatus: dependencies.appStatus,
            anchorFrameProvider: dependencies.hub.statusItemAnchorFrame
        )
        quickPickerWindowController = QuickPickerWindowController(
            store: store,
            settings: dependencies.settings,
            axPermission: dependencies.axPermission,
            anchorFrameProvider: dependencies.hub.statusItemAnchorFrame,
            onOpenFullHistory: { [weak self] in self?.showHistoryWindow() },
            onStartPasteSequence: { [weak pasteSequenceCoordinator] in pasteSequenceCoordinator?.start() }
        )

        let enrichment = ClipEnrichmentService(store: store, settings: dependencies.settings)
        enrichmentService = enrichment
        if dependencies.settings.aiTaggingEnabled { enrichment.start() }
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankAITaggingChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let enrichment = self.enrichmentService else { return }
                    if self.dependencies.settings.aiTaggingEnabled { enrichment.start() } else { enrichment.stop() }
                }
            }
        )

        dependencies.hub.setPrimaryPanelProvider { [weak self] in self?.makePrimaryPanel() ?? .empty }
        dependencies.hub.setPrimaryIconDimmed(watcher.isPaused)

        registerHotkey()
        observerTokens.append(
            NotificationCenter.default.addObserver(
                forName: .yankHotkeyChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.registerHotkey()
                    self.updateTooltip()
                }
            }
        )

        updateTooltip()
    }

    private func makePasteSequenceCoordinator(for watcher: ClipboardWatcher) -> PasteSequenceCoordinator {
        let coordinator = PasteSequenceCoordinator(
            dependencies: dependencies,
            watcher: watcher,
            onActivityChanged: { [weak self] in self?.updateTooltip() }
        )
        pasteSequenceCoordinator = coordinator
        watcher.onEligibleTextCopy = { [weak coordinator] generation, text, capturedAt in
            coordinator?.record(
                pasteboardGeneration: generation,
                text: text,
                capturedAt: capturedAt
            )
        }
        return coordinator
    }

    func stop() {
        tearDownCloudSync()
        pasteSequenceCoordinator?.stop()
        pasteSequenceCoordinator = nil
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observerTokens.removeAll()
        clipboardWatcher?.stopWatching()
        clipboardWatcher = nil
        dependencies.hotkeys.unregister()
        dependencies.hub.setPrimaryPanelProvider(nil)
        dependencies.hub.setPrimaryIconDimmed(false)
        cancelDelayedQuickPickerOpen()
        quickPickerWindowController?.close()
        quickPickerWindowController = nil
        enrichmentService?.stop()
        enrichmentService = nil
        historyWindowController?.close()
        historyWindowController = nil
    }

    // MARK: - Forwarded from the composition root

    /// Handle a CloudKit silent push delivered to the app delegate, or a wake/periodic
    /// catch-up trigger. A trigger arriving mid-pull is coalesced into one follow-up pull
    /// rather than dropped — the in-flight pull may predate the record that triggered it.
    func handleRemoteChange() {
        remoteChangeTrigger.trigger()
    }

    private func pullRemoteChange() async -> Bool {
        guard dependencies.settings.syncEnabled else { return false }
        guard let cloudSync else {
            configureCloudSync()
            return false
        }
        return await cloudSync.handleRemoteChange()
    }

    /// Surface Settings (the recovery path when the menu-bar icon is hidden).
    func openSettings() {
        historyWindowController?.openSettings()
    }

    private func registerHotkey() {
        let settings = dependencies.settings
        let registered = dependencies.hotkeys.register(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers,
            onFire: { [weak self] in self?.handleGlobalShortcut() }
        )
        if !registered {
            Log.hotkey.warning("Global hotkey registration failed — conflicting app or permission denied.")
        }
        dependencies.appStatus.hotkeyRegistrationFailed = !registered
        if !registered {
            pasteSequenceCoordinator?.hotkeyRegistrationDidFail()
        }
    }

    private func configureCloudSync() {
        guard dependencies.settings.syncEnabled else {
            tearDownCloudSync(reason: .disabled)
            return
        }
        guard CloudContainerProvisioning.isProvisioned(for: Self.cloudContainerID) else {
            Log.app.info("CloudKit container not provisioned; running local-only.")
            tearDownCloudSync(reason: .notProvisioned)
            return
        }
        guard cloudSync == nil, cloudSyncConfigureTask == nil else { return }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let didReset = await CloudKitAccountChangeGuard.resetIfAccountChanged(
                containerIdentifier: Self.cloudContainerID,
                defaultsKey: Self.accountIdentityDefaultsKey,
                defaults: .standard,
                resolveIdentity: self.accountIdentityProvider,
                resetPersistedState: CloudKitSyncService.resetPersistedState(containerIdentifier:defaults:)
            )
            if didReset {
                Log.app.info("iCloud account changed; reset CloudKit sync checkpoints.")
            }
            guard !Task.isCancelled, self.cloudSyncConfigureTask?.id == taskID else { return }
            self.cloudSyncConfigureTask = nil
            guard self.cloudSync == nil else { return }
            let sync = CloudKitSyncService(
                containerIdentifier: Self.cloudContainerID,
                store: self.store,
                settingsStore: self.settingsSyncBridge
            )
            self.cloudSync = sync
            NSApp.registerForRemoteNotifications()
            self.startCloudSync(sync)
            self.startCatchUpTriggers()
        }
        cloudSyncConfigureTask = (taskID, task)
    }

    private func startCloudSync(_ sync: CloudKitSyncService, retryAttempt: Int = 0) {
        let taskID = UUID()
        let task = Task { @MainActor [weak self, weak sync] in
            guard let sync else { return }
            let result = await sync.start()
            guard let self,
                  !Task.isCancelled,
                  self.cloudSyncStartTask?.id == taskID,
                  self.cloudSync === sync else { return }
            self.cloudSyncStartTask = nil
            if case .failed(let message) = result {
                Log.app.error("CloudKit sync failed to start: \(message, privacy: .public)")
                self.cloudSyncStartRetry.scheduleNext(afterAttempt: retryAttempt) { [weak self, weak sync] in
                    // A retry is a no-op once the service is torn down or replaced.
                    guard let self, let sync, self.cloudSync === sync else { return }
                    self.startCloudSync(sync, retryAttempt: retryAttempt + 1)
                }
            }
        }
        cloudSyncStartTask = (taskID, task)
    }

    /// Wake and periodic pulls cover what silent pushes miss: they're best-effort and dropped
    /// while the Mac sleeps, and this app runs for weeks between relaunches.
    private func startCatchUpTriggers() {
        guard wakeObserverToken == nil else { return }
        wakeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleRemoteChange() }
        }
        periodicRemotePullTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicRemotePullInterval)
                guard !Task.isCancelled, let self else { return }
                self.handleRemoteChange()
            }
        }
    }

    private func stopCatchUpTriggers() {
        if let wakeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserverToken)
            self.wakeObserverToken = nil
        }
        periodicRemotePullTask?.cancel()
        periodicRemotePullTask = nil
    }

    private func tearDownCloudSync(reason: SyncStatus.Reason? = nil) {
        cloudSync?.stop()
        cloudSyncConfigureTask?.task.cancel()
        cloudSyncConfigureTask = nil
        cloudSyncStartTask?.task.cancel()
        cloudSyncStartTask = nil
        cloudSyncStartRetry.cancel()
        remoteChangeTrigger.cancel()
        stopCatchUpTriggers()
        cloudSync = nil
        NSApp.unregisterForRemoteNotifications()
        if let reason {
            store.markSyncUnavailable(reason: reason)
        }
    }

    private func handleGlobalShortcut() {
        if pasteSequenceCoordinator?.handleShortcut() == true { return }
        toggleShortcutTargetWindow()
    }

    private func toggleShortcutTargetWindow() {
        switch dependencies.settings.shortcutOpenTarget {
        case .quickPicker:
            toggleQuickPickerWindow()
        case .fullHistory:
            toggleHistoryWindow()
        }
    }

    private func toggleQuickPickerWindow() {
        if let window = quickPickerWindowController?.window, window.isVisible {
            quickPickerWindowController?.close()
        } else {
            showQuickPickerWindow()
        }
    }

    private func toggleHistoryWindow() {
        if let window = historyWindowController?.window, window.isVisible {
            historyWindowController?.close()
        } else {
            showHistoryWindow()
        }
    }

    private func showQuickPickerWindow(afterDebugPointerSettle: Bool = false) {
        historyWindowController?.close()
        cancelDelayedQuickPickerOpen()
        #if DEBUG
        if afterDebugPointerSettle, DebugQuickPickerSimulation.mouseAnchorEnabled {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.delayedQuickPickerOpen = nil
                self.historyWindowController?.close()
                self.quickPickerWindowController?.showWindow(nil)
            }
            delayedQuickPickerOpen = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + DebugQuickPickerSimulation.pointerSettleDelay,
                                          execute: workItem)
            return
        }
        #endif
        quickPickerWindowController?.showWindow(nil)
    }

    private func showHistoryWindow() {
        cancelDelayedQuickPickerOpen()
        quickPickerWindowController?.close()
        historyWindowController?.showWindow(nil)
    }

    private func cancelDelayedQuickPickerOpen() {
        delayedQuickPickerOpen?.cancel()
        delayedQuickPickerOpen = nil
    }

    private func updateTooltip() {
        let settings = dependencies.settings
        let shortcut = "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
        let action = pasteSequenceCoordinator?.isActive == true ? "Paste next" : "Yank"
        dependencies.hub.setTooltip("\(action) — \(shortcut)\nRight-click for options")
    }

    // MARK: - Hub command panel

    /// Snapshot the clipboard's current state into the panel the hub renders on right-click.
    private func makePrimaryPanel() -> HubPrimaryPanel {
        let settings = dependencies.settings
        let shortcut = "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
        return HubPrimaryPanel(
            shortcut: shortcut,
            shortcutOpenTarget: settings.shortcutOpenTarget,
            isPaused: clipboardWatcher?.isPaused ?? false,
            ignoreNextCopyArmed: clipboardWatcher?.ignoreNextChange ?? false,
            hotkeyUnavailable: dependencies.appStatus.hotkeyRegistrationFailed,
            itemCount: store.items.count,
            isPasteSequenceActive: pasteSequenceCoordinator?.isActive ?? false,
            pasteSequenceItemCount: pasteSequenceCoordinator?.itemCount ?? 0,
            canRepeatPasteSequence: pasteSequenceCoordinator?.canRepeatPrevious ?? false,
            onOpenQuickPicker: { [weak self] in self?.showQuickPickerWindow(afterDebugPointerSettle: true) },
            onOpenHistory: { [weak self] in self?.showHistoryWindow() },
            onTogglePasteSequence: { [weak self] in self?.pasteSequenceCoordinator?.toggle() },
            onRepeatPasteSequence: { [weak self] previousApp in
                self?.pasteSequenceCoordinator?.repeatPrevious(previousApp: previousApp)
            },
            onTogglePause: { [weak self] in self?.togglePause() },
            onIgnoreNextCopy: { [weak self] in self?.clipboardWatcher?.ignoreNextCopy() },
            onFixShortcut: { [weak self] in self?.openSettings() },
            onSettings: { [weak self] in self?.openSettings() },
            onClear: { [weak self] in self?.clearHistory() }
        )
    }

    private func togglePause() {
        guard let watcher = clipboardWatcher else { return }
        let nowPaused = !watcher.isPaused
        if nowPaused {
            if pasteSequenceCoordinator?.isActive == true { pasteSequenceCoordinator?.cancel() }
            watcher.pause()
        } else {
            watcher.resume()
        }
        dependencies.hub.setPrimaryIconDimmed(nowPaused)
    }

    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Clipboard History?"
        alert.informativeText = "This will permanently delete all clipboard items."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            pasteSequenceCoordinator?.discard()
            store.clear()
        }
    }
}

/// Detects an iCloud account switch ahead of constructing a fresh sync service, so the
/// previous account's checkpoints are reset first (see
/// `CloudKitSyncService.resetPersistedState` for why they must not carry across).
enum CloudKitAccountChangeGuard {
    /// Compares the resolved account identity against the one persisted under `defaultsKey`,
    /// resetting `containerIdentifier`'s sync checkpoints when they differ. A first run (no
    /// persisted identity yet) only records the identity — it must never wipe a healthy
    /// checkpoint. A failed probe (offline, no account) leaves everything untouched. Returns
    /// whether a reset happened, so the caller can log it.
    @discardableResult
    @MainActor
    static func resetIfAccountChanged(
        containerIdentifier: String,
        defaultsKey: String,
        defaults: UserDefaults,
        resolveIdentity: () async throws -> String,
        resetPersistedState: (String, UserDefaults) -> Void
    ) async -> Bool {
        let currentIdentity: String
        do {
            currentIdentity = try await resolveIdentity()
        } catch {
            return false
        }
        let previousIdentity = defaults.string(forKey: defaultsKey)
        var didReset = false
        if let previousIdentity, previousIdentity != currentIdentity {
            resetPersistedState(containerIdentifier, defaults)
            didReset = true
        }
        defaults.set(currentIdentity, forKey: defaultsKey)
        return didReset
    }
}

/// Runs an async operation on trigger, coalescing any trigger that arrives while one is
/// already in flight into exactly one follow-up run — a trigger is remembered, never dropped,
/// but a burst never queues more than one extra run after the current one finishes.
@MainActor
final class CoalescingTrigger {
    private var active: (id: UUID, task: Task<Void, Never>)?
    private var pending = false
    private let operation: () async -> Void

    init(operation: @escaping () async -> Void) {
        self.operation = operation
    }

    func trigger() {
        guard active == nil else {
            pending = true
            return
        }
        run()
    }

    private func run() {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.operation()
            guard let self, !Task.isCancelled, self.active?.id == taskID else { return }
            self.active = nil
            if self.pending {
                self.pending = false
                self.run()
            }
        }
        active = (taskID, task)
    }

    /// Cancels any in-flight run and drops a remembered trigger without starting it.
    func cancel() {
        active?.task.cancel()
        active = nil
        pending = false
    }
}

/// Schedules a bounded-backoff retry, single-flight: a new schedule call replaces any pending
/// one. Exhausting `delays` is a normal terminal state — the caller decides what recovers from
/// there.
@MainActor
final class BackoffRetryScheduler {
    private let delays: [Duration]
    private var pendingRetry: Task<Void, Never>?

    init(delays: [Duration]) {
        self.delays = delays
    }

    /// Schedules `action` after `delays[afterAttempt]`, or no-ops once the schedule is exhausted.
    func scheduleNext(afterAttempt attempt: Int, action: @escaping () -> Void) {
        guard attempt < delays.count else { return }
        pendingRetry?.cancel()
        let delay = delays[attempt]
        pendingRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingRetry = nil
            action()
        }
    }

    func cancel() {
        pendingRetry?.cancel()
        pendingRetry = nil
    }
}
