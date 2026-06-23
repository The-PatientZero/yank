import Cocoa
import CloudKit

/// Dependencies owned by the composition root and injected into the clipboard runtime.
@MainActor
struct ClipboardDependencies {
    let store: ClipboardStore
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
    private var delayedQuickPickerOpen: DispatchWorkItem?
    private var cloudSync: CloudKitSyncService?
    private var observerTokens: [NSObjectProtocol] = []

    private var store: ClipboardStore { dependencies.store }

    init(dependencies: ClipboardDependencies) {
        self.dependencies = dependencies
    }

    // `isolated deinit` runs cleanup on the main actor (the runtime schedules a hop if the last
    // release lands off-main), so it never traps the way `MainActor.assumeIsolated` would, while
    // still allowing access to the non-Sendable `observerTokens`. It's only a backstop:
    // `stop()` is the normal app-termination path.
    isolated deinit {
        stop()
    }

    func start() {
        let watcher = ClipboardWatcher(store: store, settings: SettingsManager.shared.captureSettings)
        watcher.startWatching()
        clipboardWatcher = watcher

        // Capture reads a value snapshot, so each preference save re-injects the current settings
        // into both store and watcher. The snapshot is `Equatable`, so unchanged values no-op.
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankCaptureSettingsChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let snapshot = SettingsManager.shared.captureSettings
                    self.store.captureSettings = snapshot
                    self.clipboardWatcher?.captureSettings = snapshot
                }
            }
        )

        // Index clips into system-wide Spotlight only when the user has opted in: clipboard
        // history can hold secrets, so system-wide indexing is off by default.
        if SettingsManager.shared.spotlightIndexingEnabled {
            SpotlightIndexer.index(store.items)
        }
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankLocalStoreDidChange,
                                                   object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, SettingsManager.shared.spotlightIndexingEnabled else { return }
                    SpotlightIndexer.schedule(self.store.items)
                }
            }
        )
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankSpotlightIndexingChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if SettingsManager.shared.spotlightIndexingEnabled {
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
            axPermission: dependencies.axPermission,
            appStatus: dependencies.appStatus,
            anchorFrameProvider: dependencies.hub.statusItemAnchorFrame
        )
        quickPickerWindowController = QuickPickerWindowController(
            store: store,
            axPermission: dependencies.axPermission,
            anchorFrameProvider: dependencies.hub.statusItemAnchorFrame,
            onOpenFullHistory: { [weak self] in self?.showHistoryWindow() }
        )

        dependencies.hub.setPrimaryPanelProvider { [weak self] in self?.makePrimaryPanel() ?? .empty }
        dependencies.hub.setPrimaryIconDimmed(watcher.isPaused)

        registerHotkey()
        observerTokens.append(
            NotificationCenter.default.addObserver(forName: .yankHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.registerHotkey()
                    self.updateTooltip()
                }
            }
        )

        updateTooltip()
    }

    func stop() {
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
        historyWindowController?.close()
        historyWindowController = nil
        cloudSync = nil
    }

    // MARK: - Forwarded from the composition root

    /// Handle a CloudKit silent push delivered to the app delegate.
    func handleRemoteChange() {
        Task { @MainActor in
            _ = await pullRemoteChange()
        }
    }

    private func pullRemoteChange() async -> Bool {
        guard SettingsManager.shared.syncEnabled else { return false }
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
        let settings = SettingsManager.shared
        let ok = dependencies.hotkeys.register(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers,
            onFire: { [weak self] in self?.toggleShortcutTargetWindow() }
        )
        if !ok {
            Log.hotkey.warning("Global hotkey registration failed — conflicting app or permission denied.")
        }
        dependencies.appStatus.hotkeyRegistrationFailed = !ok
    }

    private func startSync(_ sync: CloudKitSyncService) async {
        switch await sync.start() {
        case .started:
            break
        case .failed(let message):
            Log.app.error("CloudKit sync failed to start: \(message, privacy: .public)")
        }
    }

    private func configureCloudSync() {
        guard SettingsManager.shared.syncEnabled else {
            cloudSync = nil
            NSApp.unregisterForRemoteNotifications()
            store.markSyncUnavailable(reason: .disabled)
            return
        }
        guard CloudContainerProvisioning.isProvisioned(for: Self.cloudContainerID) else {
            Log.app.info("CloudKit container not provisioned; running local-only.")
            cloudSync = nil
            NSApp.unregisterForRemoteNotifications()
            store.markSyncUnavailable(reason: .notProvisioned)
            return
        }
        guard cloudSync == nil else { return }
        let sync = CloudKitSyncService(containerIdentifier: Self.cloudContainerID, store: store)
        cloudSync = sync
        NSApp.registerForRemoteNotifications()
        Task { await self.startSync(sync) }
    }

    private func toggleShortcutTargetWindow() {
        switch SettingsManager.shared.shortcutOpenTarget {
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
        let settings = SettingsManager.shared
        let shortcut = "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
        dependencies.hub.setTooltip("Yank — \(shortcut)\nRight-click for options")
    }

    // MARK: - Hub command panel

    /// Snapshot the clipboard's current state into the panel the hub renders on right-click.
    private func makePrimaryPanel() -> HubPrimaryPanel {
        let settings = SettingsManager.shared
        let shortcut = "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
        return HubPrimaryPanel(
            shortcut: shortcut,
            shortcutOpenTarget: settings.shortcutOpenTarget,
            isPaused: clipboardWatcher?.isPaused ?? false,
            ignoreNextCopyArmed: clipboardWatcher?.ignoreNextChange ?? false,
            hotkeyUnavailable: dependencies.appStatus.hotkeyRegistrationFailed,
            itemCount: store.items.count,
            onOpenQuickPicker: { [weak self] in self?.showQuickPickerWindow(afterDebugPointerSettle: true) },
            onOpenHistory: { [weak self] in self?.showHistoryWindow() },
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
        if nowPaused { watcher.pause() } else { watcher.resume() }
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
            store.clear()
        }
    }
}
