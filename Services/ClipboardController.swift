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
    /// Whether an iCloud account is signed in right now. Seam for tests, like the identity.
    private let accountStatusProvider: () async throws -> CKAccountStatus
    private var cloudSyncConfigureTask: (id: UUID, task: Task<Void, Never>)?
    private var cloudSyncStartTask: (id: UUID, task: Task<Void, Never>)?
    /// Whether the current service has completed a full bring-up. Until it has, "Sync now"
    /// repeats the bring-up; afterwards it only pulls and pushes.
    private var cloudSyncDidStart = false
    /// Set by "Sync now" so the next pull reports "Syncing…" itself.
    private var manualSyncRequested = false
    /// Bounded backoff for a failed `start()` (offline at login, CloudKit throttle). Once
    /// exhausted, the network, wake, hourly, account and "Sync now" triggers start it again.
    private let cloudSyncStartRetry = BackoffRetryScheduler(delays: ClipboardController.cloudSyncStartRetryDelays)
    /// Bounded backoff for a recovery pull that failed after setup had completed, so a pull
    /// that raced the network coming back is not stuck until the next trigger.
    private let recoveryRetry = BackoffRetryScheduler(delays: ClipboardController.cloudSyncStartRetryDelays)
    private var recoveryRetryAttempt = 0
    /// A trigger arrived while setup was running; one pull runs when setup succeeds, so a push
    /// that landed after the setup pull fetched is not lost.
    private var followUpAfterSetup = false
    /// Watches the network and the iCloud account while sync is enabled; it outlives the sync
    /// service so an account change can replace the service.
    private var recoveryTriggers: SyncRecoveryTriggers?
    private var accountChangeTask: Task<Void, Never>?
    /// Coalesces a CloudKit silent push with the wake/periodic catch-up triggers below into at
    /// most one follow-up pull when they arrive while a pull is already in flight.
    private lazy var remoteChangeTrigger = CoalescingTrigger { [weak self] in
        _ = await self?.recoverSync()
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
        },
        accountStatusProvider: @escaping () async throws -> CKAccountStatus = {
            try await CKContainer(identifier: ClipboardController.cloudContainerID).accountStatus()
        }
    ) {
        self.dependencies = dependencies
        self.settingsSyncBridge = SettingsSyncBridge(settings: dependencies.settings, store: dependencies.store)
        self.accountIdentityProvider = accountIdentityProvider
        self.accountStatusProvider = accountStatusProvider
    }

    // `isolated deinit` hops to the main actor for cleanup (unlike `MainActor.assumeIsolated`, it
    // never traps) and can safely touch the non-Sendable `observerTokens`. Backstop only —
    // `stop()` is the normal termination path.
    isolated deinit {
        stop()
    }

    func start() {
        let watcher = ClipboardWatcher(store: store, settings: dependencies.settings.captureSettings)
        let pasteSequenceCoordinator = makePasteSequenceCoordinator(for: watcher)
        // A saved pause is restored before the timer would start, so nothing is captured. Resume
        // re-reads the change count, so what was copied during the pause is never captured later.
        if dependencies.settings.capturePaused { watcher.pause() }
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

        // Off by default — clips can hold secrets; see `SettingsManager.spotlightIndexingEnabled`.
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

        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankSyncNowRequested,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.syncNow()
                }
            }
        )
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankKeepClipsLocalRequested,
                                                   object: nil, queue: .main) { [weak self] note in
                let clipIDs = note.userInfo?[SyncNotificationKey.clipIDs] as? [UUID] ?? []
                Task { @MainActor in
                    self?.keepClipsLocalOnly(clipIDs)
                }
            }
        )
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankSyncStatusChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.updateTooltip()
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
            onStartPasteSequence: { [weak pasteSequenceCoordinator] in pasteSequenceCoordinator?.start() },
            onResumeCapture: { [weak self] in self?.setCapturePaused(false) }
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
        dependencies.hub.showCapturePaused(watcher.isPaused)

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
        // Visual reset only: quitting and the update relaunch keep the saved pause.
        dependencies.hub.showCapturePaused(false)
        cancelDelayedQuickPickerOpen()
        quickPickerWindowController?.close()
        quickPickerWindowController = nil
        enrichmentService?.stop()
        enrichmentService = nil
        historyWindowController?.close()
        historyWindowController = nil
    }

    // MARK: - Forwarded from the composition root

    /// Handle a CloudKit silent push delivered to the app delegate, or a wake, periodic, network
    /// or account catch-up trigger. A trigger arriving mid-pull is coalesced into one follow-up
    /// pull rather than dropped — the in-flight pull may predate the record that triggered it.
    func handleRemoteChange() {
        recoveryRetry.cancel()
        recoveryRetryAttempt = 0
        remoteChangeTrigger.trigger()
    }

    /// The one way sync catches up: repeats setup when it never completed, remembers a trigger
    /// that arrives while setup runs, and otherwise pulls and pushes. A failed pull retries on a
    /// bounded schedule.
    private func recoverSync() async -> Bool {
        guard dependencies.settings.syncEnabled else { return false }
        guard let cloudSync else {
            configureCloudSync()
            return false
        }
        guard cloudSyncStartTask == nil else {
            followUpAfterSetup = true
            return false
        }
        guard cloudSyncDidStart else {
            restartSetup(cloudSync)
            return false
        }
        let succeeded = await pullAndPush(cloudSync)
        if succeeded {
            recoveryRetryAttempt = 0
        } else if self.cloudSync === cloudSync {
            let attempt = recoveryRetryAttempt
            recoveryRetryAttempt += 1
            recoveryRetry.scheduleNext(afterAttempt: attempt) { [weak self] in
                self?.remoteChangeTrigger.trigger()
            }
        }
        return succeeded
    }

    private func pullAndPush(_ cloudSync: CloudKitSyncService) async -> Bool {
        guard manualSyncRequested else { return await cloudSync.handleRemoteChange() }
        manualSyncRequested = false
        let previousStatus = store.syncStatus
        let previousFailureKind = store.syncFailureKind
        store.markSyncStarted()
        let succeeded = await cloudSync.handleRemoteChange()
        // A service stopped mid-pull reports nothing; leave the status as it was before the click.
        if store.syncStatus == .syncing {
            store.restoreSyncState(previousStatus, failureKind: previousFailureKind)
        }
        return succeeded
    }

    /// Starts setup again from the beginning of its retry schedule.
    private func restartSetup(_ cloudSync: CloudKitSyncService) {
        cloudSyncStartRetry.cancel()
        startCloudSync(cloudSync)
    }

    /// "Sync now" from Settings or the menu. A service that never finished starting repeats its
    /// bring-up; one that did only pulls and pushes (through the coalescing trigger, so quick
    /// repeated clicks run one follow-up at most).
    private func syncNow() {
        guard dependencies.settings.syncEnabled else { return }
        guard let cloudSync else {
            configureCloudSync()
            return
        }
        guard cloudSyncStartTask == nil else { return }
        guard cloudSyncDidStart else {
            restartSetup(cloudSync)
            return
        }
        manualSyncRequested = true
        handleRemoteChange()
    }

    private func keepClipsLocalOnly(_ clipIDs: [UUID]) {
        cloudSync?.keepLocalOnly(clipIDs: clipIDs)
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
        startRecoveryTriggers()
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
            sync.enableEncryptionRollout(deviceID: DeviceIdentity.current, statusReporter: self.store)
            self.cloudSync = sync
            self.cloudSyncDidStart = false
            self.startCloudSync(sync)
            self.startCatchUpTriggers()
        }
        cloudSyncConfigureTask = (taskID, task)
    }

    private func startCloudSync(_ sync: CloudKitSyncService, retryAttempt: Int = 0) {
        // Every setup attempt asks the system for pushes again; registering is idempotent.
        NSApp.registerForRemoteNotifications()
        let taskID = UUID()
        let task = Task { @MainActor [weak self, weak sync] in
            guard let sync else { return }
            let result = await sync.start()
            guard let self,
                  !Task.isCancelled,
                  self.cloudSyncStartTask?.id == taskID,
                  self.cloudSync === sync else { return }
            self.cloudSyncStartTask = nil
            if case .started = result {
                self.cloudSyncDidStart = true
                if self.followUpAfterSetup {
                    self.followUpAfterSetup = false
                    self.remoteChangeTrigger.trigger()
                }
            }
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

    /// Watches for the network coming back and for iCloud account changes while sync is enabled.
    private func startRecoveryTriggers() {
        guard recoveryTriggers == nil else { return }
        let triggers = SyncRecoveryTriggers(
            container: CKContainer(identifier: Self.cloudContainerID),
            onNetworkRestored: { [weak self] in self?.handleRemoteChange() },
            onAccountChanged: { [weak self] in self?.accountDidChange() }
        )
        triggers.start()
        recoveryTriggers = triggers
    }

    /// The iCloud account notification also fires for events that are not a switch, so the
    /// running service is replaced only when the identity differs from the one it was built for
    /// or the account is gone. A failed probe (offline) leaves everything as it is.
    private func accountDidChange() {
        guard dependencies.settings.syncEnabled else { return }
        accountChangeTask?.cancel()
        accountChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.probeAccountStatus()
            let identity = await self.probeAccountIdentity()
            guard !Task.isCancelled else { return }
            let accountGone = status == .noAccount || status == .restricted
            if let identity, !accountGone {
                let persisted = UserDefaults.standard.string(forKey: Self.accountIdentityDefaultsKey)
                if self.cloudSync != nil, persisted == nil || persisted == identity {
                    UserDefaults.standard.set(identity, forKey: Self.accountIdentityDefaultsKey)
                    // Signing back in to the same account: a service whose setup failed while
                    // the account was gone repeats it.
                    if !self.cloudSyncDidStart { self.handleRemoteChange() }
                    return
                }
            } else if !accountGone {
                return
            }
            Log.app.info("iCloud account changed; replacing the sync service.")
            self.tearDownCloudSync(stopRecoveryTriggers: false)
            self.configureCloudSync()
        }
    }

    private func probeAccountStatus() async -> CKAccountStatus? {
        do {
            return try await accountStatusProvider()
        } catch {
            Log.app.info("Could not check the iCloud account status: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func probeAccountIdentity() async -> String? {
        do {
            return try await accountIdentityProvider()
        } catch {
            Log.app.info("Could not read the iCloud account identity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `stopRecoveryTriggers: false` is for replacing the service after an account change: the
    /// network and account triggers keep running through the rebuild.
    private func tearDownCloudSync(reason: SyncStatus.Reason? = nil, stopRecoveryTriggers: Bool = true) {
        cloudSync?.stop()
        cloudSyncConfigureTask?.task.cancel()
        cloudSyncConfigureTask = nil
        cloudSyncStartTask?.task.cancel()
        cloudSyncStartTask = nil
        cloudSyncStartRetry.cancel()
        recoveryRetry.cancel()
        recoveryRetryAttempt = 0
        followUpAfterSetup = false
        remoteChangeTrigger.cancel()
        manualSyncRequested = false
        stopCatchUpTriggers()
        if stopRecoveryTriggers {
            accountChangeTask?.cancel()
            accountChangeTask = nil
            recoveryTriggers?.stop()
            recoveryTriggers = nil
        }
        cloudSync = nil
        cloudSyncDidStart = false
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
            // The history window has no pause state. With the icon hidden and capture paused, the
            // Quick Picker is the only place to see the pause and end it.
            let settings = dependencies.settings
            if settings.capturePaused && !settings.showMenuBarIcon {
                toggleQuickPickerWindow()
            } else {
                toggleHistoryWindow()
            }
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
        dependencies.hub.setTooltip(
            headline: "\(action) — \(shortcut)",
            syncProblem: syncSummary.problemLine,
            hint: "Right-click for options"
        )
    }

    // MARK: - Hub command panel

    private var syncSummary: HubSyncSummary {
        HubSyncSummary(
            status: store.syncStatus,
            failureKind: store.syncFailureKind,
            waitingCount: store.visibleWaitingClips.count
        )
    }

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
            sync: syncSummary,
            onOpenQuickPicker: { [weak self] in self?.showQuickPickerWindow(afterDebugPointerSettle: true) },
            onOpenHistory: { [weak self] in self?.showHistoryWindow() },
            onTogglePasteSequence: { [weak self] in self?.pasteSequenceCoordinator?.toggle() },
            onRepeatPasteSequence: { [weak self] previousApp in
                self?.pasteSequenceCoordinator?.repeatPrevious(previousApp: previousApp)
            },
            onTogglePause: { [weak self] in
                guard let self else { return }
                setCapturePaused(!dependencies.settings.capturePaused)
            },
            onIgnoreNextCopy: { [weak self] in self?.clipboardWatcher?.ignoreNextCopy() },
            onFixShortcut: { [weak self] in self?.openSettings() },
            onSettings: { [weak self] in self?.openSettings() },
            onSyncNow: { [weak self] in self?.syncNow() },
            onSyncOpenSettings: { SyncSystemSettings.openAppleIDPane() },
            onClear: { [weak self] in self?.clearHistory() }
        )
    }

    /// The only place the pause changes: saves the choice, applies it to the watcher and shows it.
    private func setCapturePaused(_ paused: Bool) {
        dependencies.settings.setCapturePaused(paused)
        if let watcher = clipboardWatcher {
            if paused {
                if pasteSequenceCoordinator?.isActive == true { pasteSequenceCoordinator?.cancel() }
                watcher.pause()
            } else {
                watcher.resume()
            }
        }
        dependencies.hub.showCapturePaused(paused)
    }

    private func clearHistory() {
        let alert = NSAlert()
        let syncEnabled = dependencies.settings.syncEnabled
        alert.messageText = SyncCopy.clearHistoryTitle(syncEnabled: syncEnabled)
        alert.informativeText = [
            SyncCopy.clearHistoryMessage(syncEnabled: syncEnabled),
            HeldClipsNotice.clearWarning(count: store.heldClipCount)
        ].compactMap { $0 }.joined(separator: " ")
        alert.alertStyle = .warning
        // Cancel is added first so it answers Return, and Escape; Clear must be clicked.
        alert.addButton(withTitle: "Cancel")
        let clearButton = alert.addButton(withTitle: "Clear")
        clearButton.hasDestructiveAction = true

        if alert.runModal() == .alertSecondButtonReturn {
            pasteSequenceCoordinator?.discard()
            store.clear()
        }
    }
}

/// Detects an iCloud account switch ahead of constructing a fresh sync service, so the
/// previous account's checkpoints are reset first (see
/// `CloudKitSyncService.resetPersistedState` for why they must not carry across).
enum CloudKitAccountChangeGuard {
    /// Resets `containerIdentifier`'s sync checkpoints when the resolved identity differs from the
    /// one persisted under `defaultsKey`. A first run only records the identity — it must never
    /// wipe a healthy checkpoint — and a failed probe (offline, no account) leaves it untouched.
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
