import SwiftUI
import CloudKit
import CoreSpotlight
import UIKit
import UniformTypeIdentifiers

/// Coordinates the two foreground-only freshness jobs iOS permits: importing the current
/// plain-text pasteboard generation and pulling CloudKit. In-process generation tracking plus
/// the persisted installation marker together prevent Yank's own writes from being recaptured.
enum IOSForegroundCaptureOutcome: Equatable {
    case durable
    case terminalPolicyRejection
    /// The pasteboard declares no text type, so it was acknowledged without being read.
    case noText
    case retryableFailure
}

@MainActor
final class IOSForegroundRefreshCoordinator {
    private struct InFlightCapture {
        let id: UUID
        let pasteboardChangeCount: Int
        let task: Task<IOSForegroundCaptureOutcome, Never>
    }

    static let shared = IOSForegroundRefreshCoordinator(
        acknowledgementStore: PasteboardAcknowledgementStore.live()
    )

    private var lastHandledPasteboardChangeCount: Int?
    private var latestObservedPasteboardChangeCount: Int?
    private var inFlightCapture: InFlightCapture?
    private let acknowledgementStore: PasteboardAcknowledgementStore?

    /// `acknowledgementStore` persists the handled generation across process death. Without
    /// one, the handled generation lives in memory only.
    init(acknowledgementStore: PasteboardAcknowledgementStore? = nil) {
        self.acknowledgementStore = acknowledgementStore
    }

    func markPasteboardChangeHandled(_ changeCount: Int) {
        latestObservedPasteboardChangeCount = changeCount
        lastHandledPasteboardChangeCount = changeCount
        persistAcknowledgement(changeCount)
    }

    @discardableResult
    func refresh(
        pasteboardChangeCount: Int,
        pasteboardTypes: [String],
        isAutomaticCaptureAuthorized: @escaping @MainActor () -> Bool,
        currentPasteboardChangeCount: (@MainActor () -> Int)? = nil,
        isPasteboardOwnedByThisInstallation: @escaping @MainActor () -> Bool = { false },
        readText: @escaping @MainActor () -> String?,
        capture: @escaping @MainActor (String, Int, Bool) async -> IOSForegroundCaptureOutcome,
        refreshSync: @MainActor () async -> Void
    ) async -> Bool {
        let didCapture = await processPasteboard(
            pasteboardChangeCount: pasteboardChangeCount,
            pasteboardTypes: pasteboardTypes,
            isAutomaticCaptureAuthorized: isAutomaticCaptureAuthorized,
            currentPasteboardChangeCount: currentPasteboardChangeCount,
            isPasteboardOwnedByThisInstallation: isPasteboardOwnedByThisInstallation,
            readText: readText,
            capture: capture
        )
        await refreshSync()
        return didCapture
    }

    @discardableResult
    func processPasteboard(
        pasteboardChangeCount: Int,
        pasteboardTypes: [String],
        isAutomaticCaptureAuthorized: @escaping @MainActor () -> Bool,
        currentPasteboardChangeCount: (@MainActor () -> Int)? = nil,
        isPasteboardOwnedByThisInstallation: @escaping @MainActor () -> Bool = { false },
        readText: @escaping @MainActor () -> String?,
        capture: @escaping @MainActor (String, Int, Bool) async -> IOSForegroundCaptureOutcome
    ) async -> Bool {
        guard isAutomaticCaptureAuthorized() else { return false }
        latestObservedPasteboardChangeCount = pasteboardChangeCount
        let currentPasteboardChangeCount = currentPasteboardChangeCount ?? {
            pasteboardChangeCount
        }
        // Cold launch: the in-memory marker is empty, so consult the persisted acknowledgement.
        if lastHandledPasteboardChangeCount == nil,
           acknowledgementStore?.isAcknowledged(changeCount: pasteboardChangeCount) == true {
            lastHandledPasteboardChangeCount = pasteboardChangeCount
        }
        guard pasteboardChangeCount != lastHandledPasteboardChangeCount else {
            return false
        }

        while let existing = inFlightCapture {
            if existing.pasteboardChangeCount == pasteboardChangeCount {
                let outcome = await existing.task.value
                clearInFlightCapture(existing)
                guard isAutomaticCaptureAuthorized() else { return false }
                return outcome == .durable
            }
            _ = await existing.task.value
            clearInFlightCapture(existing)
            guard isAutomaticCaptureAuthorized() else { return false }
        }

        guard isAutomaticCaptureAuthorized() else { return false }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return IOSForegroundCaptureOutcome.retryableFailure }
            return await self.resolve(
                pasteboardChangeCount: pasteboardChangeCount,
                pasteboardTypes: pasteboardTypes,
                isAutomaticCaptureAuthorized: isAutomaticCaptureAuthorized,
                currentPasteboardChangeCount: currentPasteboardChangeCount,
                isPasteboardOwnedByThisInstallation: isPasteboardOwnedByThisInstallation,
                readText: readText,
                capture: capture
            )
        }
        let inFlight = InFlightCapture(
            id: id,
            pasteboardChangeCount: pasteboardChangeCount,
            task: task
        )
        inFlightCapture = inFlight
        let outcome = await inFlight.task.value
        clearInFlightCapture(inFlight)

        return outcome == .durable
    }

    private func clearInFlightCapture(_ capture: InFlightCapture) {
        guard inFlightCapture?.id == capture.id else { return }
        inFlightCapture = nil
    }

    private func resolve(
        pasteboardChangeCount: Int,
        pasteboardTypes: [String],
        isAutomaticCaptureAuthorized: @MainActor () -> Bool,
        currentPasteboardChangeCount: @MainActor () -> Int,
        isPasteboardOwnedByThisInstallation: @MainActor () -> Bool,
        readText: @MainActor () -> String?,
        capture: @MainActor (String, Int, Bool) async -> IOSForegroundCaptureOutcome
    ) async -> IOSForegroundCaptureOutcome {
        guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
        if isPasteboardOwnedByThisInstallation() {
            guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
            updateLatestObserved(using: currentPasteboardChangeCount)
            guard latestObservedPasteboardChangeCount == pasteboardChangeCount else {
                return .retryableFailure
            }
            markCurrentGenerationHandled(pasteboardChangeCount)
            return .terminalPolicyRejection
        }

        let captureDecision = CapturePolicy(excludedBundleIDs: []).decide(
            frontmostBundleID: nil,
            pasteboardTypes: pasteboardTypes
        )
        switch captureDecision {
        case .skipConcealed, .skipExcludedApp:
            guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
            updateLatestObserved(using: currentPasteboardChangeCount)
            markCurrentGenerationHandled(pasteboardChangeCount)
            return .terminalPolicyRejection
        case .capture:
            guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
            guard PasteboardAcknowledgement.hasTextRepresentation(in: pasteboardTypes) else {
                // Nothing to read: acknowledge the generation so it is never read (and never
                // prompts for paste permission) again.
                guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
                updateLatestObserved(using: currentPasteboardChangeCount)
                markCurrentGenerationHandled(pasteboardChangeCount)
                return .noText
            }
            let hasRichContent = PasteboardArchive.isRich(utis: pasteboardTypes)
            guard let text = readText() else { return .retryableFailure }
            guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
            updateLatestObserved(using: currentPasteboardChangeCount)
            guard latestObservedPasteboardChangeCount == pasteboardChangeCount else {
                return .retryableFailure
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                markCurrentGenerationHandled(pasteboardChangeCount)
                return .terminalPolicyRejection
            }

            guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
            let outcome = await capture(text, pasteboardChangeCount, hasRichContent)
            guard isAutomaticCaptureAuthorized() else { return .retryableFailure }
            updateLatestObserved(using: currentPasteboardChangeCount)
            if outcome != .retryableFailure {
                markCurrentGenerationHandled(pasteboardChangeCount)
            }
            return outcome
        }
    }

    private func updateLatestObserved(
        using currentPasteboardChangeCount: @MainActor () -> Int
    ) {
        latestObservedPasteboardChangeCount = currentPasteboardChangeCount()
    }

    private func markCurrentGenerationHandled(_ changeCount: Int) {
        guard latestObservedPasteboardChangeCount == changeCount else { return }
        lastHandledPasteboardChangeCount = changeCount
        persistAcknowledgement(changeCount)
    }

    private func persistAcknowledgement(_ changeCount: Int) {
        do {
            try acknowledgementStore?.record(changeCount: changeCount)
        } catch {
            clipStoreLog.error("Could not persist the pasteboard acknowledgement: \(error.localizedDescription)")
        }
    }
}

/// Runs foreground work without touching the pasteboard unless the user selected
/// automatic capture. Explicit extension handoffs and CloudKit refresh in every mode.
@MainActor
enum IOSForegroundRefreshPipeline {
    static func refresh(
        currentMode: @MainActor () -> IOSForegroundCaptureMode,
        drainExplicitCaptures: @MainActor () async -> Set<String>,
        recordSuccessfulCaptureMethods: @MainActor (Set<String>) -> Void,
        captureAutomatically: @MainActor () async -> Void,
        refreshSync: @MainActor () async -> Void
    ) async {
        let sources = await drainExplicitCaptures()
        recordSuccessfulCaptureMethods(sources)
        // `drainExplicitCaptures` can suspend. Re-read the live choice immediately
        // before invoking the lazy pasteboard boundary so a queued automatic refresh
        // cannot inspect after the user switches to explicit-only.
        if currentMode() == .automatic {
            await captureAutomatically()
        }
        await refreshSync()
    }

    static func refreshAfterModeChange(
        from oldMode: IOSForegroundCaptureMode,
        to newMode: IOSForegroundCaptureMode,
        refresh: @MainActor () async -> Void
    ) async {
        guard oldMode != .automatic, newMode == .automatic else { return }
        await refresh()
    }
}

enum IOSForegroundCaptureDisclosurePresentation: Equatable {
    case hidden
    case prompt
}

struct IOSForegroundCaptureDisclosureSession: Equatable {
    private(set) var deferredForCurrentSession = false
    /// The parts of the first-run screen being shown; nil while the screen is closed. Fixed when
    /// the screen opens, so nothing that happens in the background can close it or change it.
    private(set) var activeSections: FirstRunSections?

    func presentation(
        for mode: IOSForegroundCaptureMode
    ) -> IOSForegroundCaptureDisclosurePresentation {
        mode == .undecided && !deferredForCurrentSession ? .prompt : .hidden
    }

    mutating func deferForCurrentSession() {
        deferredForCurrentSession = true
    }

    /// Opens the screen on a cold launch while the clipboard mode is undecided. Clipboard access
    /// is always shown; the capture methods and the sync choice only while set-up is unfinished,
    /// and the sync choice only when sync is off and this build can sync at all.
    mutating func beginAutomatically(
        mode: IOSForegroundCaptureMode,
        captureSetupCompleted: Bool,
        syncEnabled: Bool,
        syncAvailable: Bool
    ) {
        guard presentation(for: mode) == .prompt else { return }
        var sections: FirstRunSections = .clipboard
        if !captureSetupCompleted {
            sections.insert(.methods)
            if !syncEnabled && syncAvailable {
                sections.insert(.sync)
            }
        }
        activeSections = sections
    }

    /// Reopens the screen on the capture methods, plus clipboard access while still undecided.
    /// Never includes the sync choice, so a review cannot change sync by accident.
    mutating func beginReview(mode: IOSForegroundCaptureMode) {
        activeSections = mode == .undecided ? [.clipboard, .methods] : .methods
    }

    mutating func end() {
        activeSections = nil
    }
}

/// Notices when automatic capture keeps finding nothing to read although the clipboard holds
/// plain text, which is how a denied "Paste from Other Apps" setting looks to the app: iOS gives
/// no way to ask. It counts visits that failed, not reads, and lives in memory only.
@MainActor
@Observable
final class PasteAccessMonitor {
    /// Failed visits in a row before the banner appears.
    private static let failedVisitsBeforeBanner = 2

    private var failedVisits = 0
    private var currentVisitFailed = false

    var isDenied: Bool { failedVisits >= Self.failedVisitsBeforeBanner }

    /// Called once at launch and once per return from the background.
    func beginVisit() {
        currentVisitFailed = false
    }

    /// Records a read that came back empty. Only a clipboard that declares plain text counts, so
    /// HTML-only or RTF-only content never raises the banner.
    func recordEmptyRead(declaredTypes: [String]) {
        guard !currentVisitFailed, Self.declaresPlainText(declaredTypes) else { return }
        currentVisitFailed = true
        failedVisits += 1
    }

    func recordSuccessfulRead() {
        reset()
    }

    func reset() {
        failedVisits = 0
    }

    private static func declaresPlainText(_ types: [String]) -> Bool {
        types.contains { UTType($0)?.conforms(to: .plainText) == true }
    }
}

/// What one CloudKit account probe means for the sync lifecycle. `.temporarilyUnavailable`/
/// `.couldNotDetermine` are recoverable (maintenance, pre-unlock probe, network hiccup); treating
/// them as sign-out would drop push delivery until relaunch — only absent/restricted accounts tear sync down.
/// A restricted account is its own decision so the screen can say so instead of asking to sign in.
enum IOSCloudAccountDecision: Equatable {
    case proceed
    case hardUnavailable(reason: SyncStatus.Reason)
    case restricted
    case transient(SyncFailure)
}

/// What one sync run did, for the system's report after a background push.
enum IOSSyncRunOutcome: Equatable, Sendable {
    /// The run fetched changes from CloudKit.
    case newData
    /// The run succeeded and fetched nothing, or was held back until the phone is unlocked.
    case noData
    case failed
}

/// Owns the iOS CloudKit container, service, and the one account/start/refresh workflow.
/// A SwiftUI `App` is a value, so keeping the task here gives sync-disable a stable cancellation
/// boundary and lets tests resume cancellation-ignoring account lookups deterministically.
@MainActor
@Observable
final class IOSCloudSyncController {
    struct ContainerHandle {
        let database: any CloudKitDatabase
        let accountStatus: @MainActor () async throws -> CKAccountStatus
        let userRecordID: @MainActor () async throws -> CKRecord.ID
    }

    private enum Request {
        case foreground(refreshExisting: Bool)
        case start(force: Bool)
        case remote
    }

    /// A request that arrived while an operation was running and runs once it ends. A forced
    /// start outranks a plain refresh, which a forced start also covers.
    private enum PendingRequest: Int, Comparable {
        case none
        case remote
        case forcedStart

        static func < (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private enum UnavailableStatus {
        case unavailable(SyncStatus.Reason)
        case failed(SyncFailure)
    }

    static let containerID = "iCloud.com.thepatientzero.yank"
    /// How long a transient account status (`.temporarilyUnavailable`, `.couldNotDetermine`)
    /// waits before retrying once, instead of stalling until the next foreground/push.
    private static let transientRetryDelayNanoseconds: UInt64 = 10_000_000_000
    private static let accountIdentityDefaultsKey = "cloudkit.accountIdentity.\(containerID)"

    private let store: ClipStore
    private let settings: IOSSettings
    @ObservationIgnored private let makeContainer: @MainActor () -> ContainerHandle?
    @ObservationIgnored private let makeService:
        @MainActor (any CloudKitDatabase, ClipStore, any SyncedSettingsStore) -> CloudKitSyncService
    @ObservationIgnored private let makeRecoveryTriggers: @MainActor (
        _ onNetworkRestored: @escaping @MainActor () -> Void,
        _ onAccountChanged: @escaping @MainActor () -> Void
    ) -> SyncRecoveryTriggers?
    @ObservationIgnored private let registerForRemoteNotifications: @MainActor () -> Void
    @ObservationIgnored private let unregisterForRemoteNotifications: @MainActor () -> Void
    @ObservationIgnored private let transientRetryDelayNanoseconds: UInt64
    /// The `UserDefaults` domain the sync service persists its checkpoints into — production
    /// and this controller must agree, or a reset here would clear the wrong store.
    @ObservationIgnored private let syncDefaults: UserDefaults

    @ObservationIgnored private var container: ContainerHandle?
    @ObservationIgnored private var sync: CloudKitSyncService?
    /// Whether `sync` completed `start()` at least once. `sync` alone isn't enough: it is
    /// assigned before `start()` runs so a retry reuses the same instance, but a failed
    /// bring-up must not let later requests bypass straight to pull/push.
    @ObservationIgnored private var syncStarted = false
    @ObservationIgnored private var operation: (id: UUID, task: Task<IOSSyncRunOutcome, Never>)?
    /// Bumped every time `run` starts a new operation, so a scheduled transient retry can
    /// tell whether some other request already ran in the meantime and skip itself.
    @ObservationIgnored private var operationSequence: UInt64 = 0
    @ObservationIgnored private var pendingRequest = PendingRequest.none
    /// Watches the network and the iCloud account while sync is enabled. Kept through a
    /// sign-out, so signing back in resumes sync without a relaunch.
    @ObservationIgnored private var recoveryTriggers: SyncRecoveryTriggers?
    @ObservationIgnored private var accountChangeTask: Task<Void, Never>?
    @ObservationIgnored private var transientRetryTask: Task<Void, Never>?
    /// The iCloud account identity resolved this controller lifecycle, so routine foregrounds
    /// don't re-probe it. Cleared in `stop()`.
    @ObservationIgnored private var cachedAccountIdentity: String?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    /// Owned here because the sync service holds it weakly, the same way it holds the store.
    /// The service observes settings choices itself; this root only supplies the port.
    @ObservationIgnored private let settingsBridge: IOSSyncedSettingsBridge

    private(set) var iCloudSignedOut = false

    init(
        store: ClipStore,
        settings: IOSSettings,
        makeContainer: @escaping @MainActor () -> ContainerHandle? = IOSCloudSyncController.makeLiveContainer,
        makeService: @escaping @MainActor (
            any CloudKitDatabase,
            ClipStore,
            any SyncedSettingsStore
        ) -> CloudKitSyncService = { database, store, settingsStore in
            let service = CloudKitSyncService(
                containerIdentifier: IOSCloudSyncController.containerID,
                store: store,
                database: database,
                settingsStore: settingsStore
            )
            service.enableEncryptionRollout(deviceID: DeviceIdentity.current, statusReporter: store)
            return service
        },
        makeRecoveryTriggers: @escaping @MainActor (
            _ onNetworkRestored: @escaping @MainActor () -> Void,
            _ onAccountChanged: @escaping @MainActor () -> Void
        ) -> SyncRecoveryTriggers? = IOSCloudSyncController.makeLiveRecoveryTriggers,
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        },
        unregisterForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.unregisterForRemoteNotifications()
        },
        transientRetryDelayNanoseconds: UInt64 = IOSCloudSyncController.transientRetryDelayNanoseconds,
        syncDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.settings = settings
        self.makeContainer = makeContainer
        self.makeService = makeService
        self.makeRecoveryTriggers = makeRecoveryTriggers
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterForRemoteNotifications = unregisterForRemoteNotifications
        self.transientRetryDelayNanoseconds = transientRetryDelayNanoseconds
        self.syncDefaults = syncDefaults
        self.settingsBridge = IOSSyncedSettingsBridge(settings: settings, store: store)
    }

    // Sync waits for the saved history: a pull applied over an unloaded store would lose the
    // remote clips, and the pull-position restart reads a marker the load may still be writing.
    @discardableResult
    func refreshForeground() async -> IOSSyncRunOutcome {
        await store.hydrate()
        return await run(.foreground(refreshExisting: true))
    }

    func start(force: Bool = false) async {
        await store.hydrate()
        _ = await run(.start(force: force))
    }

    func handleRemoteChange() async -> IOSSyncRunOutcome {
        await store.hydrate()
        return await run(.remote)
    }

    /// Stops waiting for these clips; they stay on this iPhone until edited. Only reachable
    /// while a service exists, because the waiting list is cleared when it is torn down.
    func keepLocalOnly(clipIDs: [UUID]) {
        sync?.keepLocalOnly(clipIDs: clipIDs)
    }

    func stop() {
        lifecycleGeneration &+= 1
        sync?.stop()
        syncStarted = false
        transientRetryTask?.cancel()
        transientRetryTask = nil
        accountChangeTask?.cancel()
        accountChangeTask = nil
        recoveryTriggers?.stop()
        recoveryTriggers = nil
        pendingRequest = .none
        cachedAccountIdentity = nil
        operation?.task.cancel()
        operation = nil
        sync = nil
        container = nil
        unregisterForRemoteNotifications()
        iCloudSignedOut = false
        store.markSyncUnavailable(reason: .disabled)
    }

    /// Runs `request`, or, when an operation is already running, remembers what it adds and
    /// answers with the outcome of the run that serves it. The operation task runs the
    /// remembered request after its own, so a caller never sees an earlier run's result for
    /// work that arrived later.
    private func run(
        _ request: Request,
        isTransientRetryAttempt: Bool = false
    ) async -> IOSSyncRunOutcome {
        if let operation {
            remember(request)
            return await operation.task.value
        }
        guard settings.syncEnabled else {
            stop()
            return .failed
        }
        startRecoveryTriggers()

        let generation = lifecycleGeneration
        let operationID = UUID()
        operationSequence &+= 1
        let task = Task { @MainActor [weak self] () -> IOSSyncRunOutcome in
            guard let self else { return .failed }
            var outcome = await self.perform(
                request,
                generation: generation,
                isTransientRetryAttempt: isTransientRetryAttempt
            )
            while let next = self.takePendingRequest(generation: generation) {
                self.operationSequence &+= 1
                outcome = await self.perform(next, generation: generation)
            }
            // No suspension since the last check for a remembered request, so one arriving
            // after this point starts a new operation instead of waiting on a finished one.
            if self.operation?.id == operationID {
                self.operation = nil
            }
            return outcome
        }
        operation = (operationID, task)
        return await task.value
    }

    private func remember(_ request: Request) {
        switch request {
        case .remote, .foreground(refreshExisting: true):
            pendingRequest = max(pendingRequest, .remote)
        case .start(force: true):
            pendingRequest = .forcedStart
            clipStoreLog.notice("Forced sync start queued behind running operation")
        case .foreground(refreshExisting: false), .start(force: false):
            break
        }
    }

    private func takePendingRequest(generation: UInt64) -> Request? {
        let pending = pendingRequest
        pendingRequest = .none
        guard isActive(generation) else { return nil }
        switch pending {
        case .none:
            return nil
        case .remote:
            return .remote
        case .forcedStart:
            clipStoreLog.notice("Forced sync start running after the earlier operation")
            return .start(force: true)
        }
    }

    private func startRecoveryTriggers() {
        guard recoveryTriggers == nil else { return }
        let triggers = makeRecoveryTriggers(
            { [weak self] in self?.networkDidReturn() },
            { [weak self] in self?.accountDidChange() }
        )
        triggers?.start()
        recoveryTriggers = triggers
    }

    /// Repeats setup if it never completed, otherwise pulls and pushes.
    private func networkDidReturn() {
        guard settings.syncEnabled else { return }
        Task { @MainActor [weak self] in
            _ = await self?.run(.remote)
        }
    }

    /// The account notification also fires for events that are not a switch, so the running
    /// service is replaced only when the account is gone or its identity differs from the one
    /// the service was built for. A failed probe (offline) leaves everything as it is.
    private func accountDidChange() {
        guard settings.syncEnabled else { return }
        accountChangeTask?.cancel()
        let generation = lifecycleGeneration
        accountChangeTask = Task { @MainActor [weak self] in
            guard let self, await self.accountChangeRequiresNewService(),
                  self.isActive(generation) else { return }
            self.dropServiceForAccountChange()
            _ = await self.run(.start(force: false))
        }
    }

    private func accountChangeRequiresNewService() async -> Bool {
        guard let probe = makeContainer() else { return false }
        do {
            switch Self.accountDecision(for: try await probe.accountStatus()) {
            case .hardUnavailable, .restricted: return true
            case .transient: return false
            case .proceed: break
            }
            let identity = try await probe.userRecordID().recordName
            guard sync != nil, syncStarted,
                  let known = cachedAccountIdentity ?? syncDefaults.string(forKey: Self.accountIdentityDefaultsKey)
            else { return true }
            return identity != known
        } catch {
            clipStoreLog.info("Could not check the iCloud account after a change: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drops the service, the container and the cached identity so the next run builds them for
    /// the account that is signed in now. Unlike `stop()` it keeps push registration and the
    /// recovery triggers, and it replaces a running operation, which belongs to the old account.
    private func dropServiceForAccountChange() {
        lifecycleGeneration &+= 1
        container = nil
        cachedAccountIdentity = nil
        sync?.stop()
        sync = nil
        syncStarted = false
        transientRetryTask?.cancel()
        transientRetryTask = nil
        pendingRequest = .none
        operation?.task.cancel()
        operation = nil
    }

    private func perform(
        _ request: Request,
        generation: UInt64,
        isTransientRetryAttempt: Bool = false
    ) async -> IOSSyncRunOutcome {
        guard isActive(generation) else { return .failed }
        // Until the files can be read, the history and settings here are not the user's real ones.
        guard !store.isAwaitingFirstUnlock else { return .noData }
        if case .remote = request, syncStarted, let sync {
            return await performRemoteChange(using: sync, generation: generation)
        }

        if container == nil {
            container = makeContainer()
        }
        guard isActive(generation) else { return .failed }
        guard let container else {
            tearDownService(
                status: .unavailable(.notProvisioned),
                generation: generation
            )
            return .failed
        }

        do {
            let status = try await container.accountStatus()
            guard isActive(generation) else { return .failed }
            switch Self.accountDecision(for: status) {
            case .proceed:
                iCloudSignedOut = false
                registerForRemoteNotifications()
                await reconcileAccountIdentity(container: container, generation: generation)
                guard isActive(generation) else { return .failed }
                restartPullPositionIfHistoryWasMissing()
            case .hardUnavailable(let reason):
                iCloudSignedOut = true
                tearDownService(
                    status: .unavailable(reason),
                    generation: generation
                )
                return .failed
            case .restricted:
                // The account screen stays up, but says "restricted" rather than "sign in".
                iCloudSignedOut = true
                tearDownService(
                    status: .failed(SyncFailure(kind: .accountRestricted)),
                    generation: generation
                )
                return .failed
            case .transient(let failure):
                // Keep the service and its push registration: the account is expected back, and
                // the next foreground refresh or silent push resumes sync without a relaunch.
                iCloudSignedOut = false
                store.markSyncFailure(failure)
                // Only the original observation schedules a retry — if the retry itself lands on
                // another transient result, the next real foreground/push is the fallback, not a
                // chained timer, so an unreachable account can't be polled forever.
                if !isTransientRetryAttempt {
                    scheduleTransientRetry(request: request, generation: generation)
                }
                return .failed
            }
        } catch {
            guard isActive(generation) else { return .failed }
            clipStoreLog.error("iCloud account lookup failed: \(error.localizedDescription, privacy: .public)")
            tearDownService(
                status: .failed(CloudKitSyncFailureClassifier.classify(error)),
                generation: generation
            )
            return .failed
        }

        guard isActive(generation) else { return .failed }
        switch request {
        case .foreground(let refreshExisting):
            if refreshExisting, syncStarted, let sync {
                return await performRemoteChange(using: sync, generation: generation)
            }
            return await performStart(force: false, container: container, generation: generation)
                ? .noData : .failed
        case .start(let force):
            return await performStart(force: force, container: container, generation: generation)
                ? .noData : .failed
        case .remote:
            let existing = sync
            let fetchedBefore = existing?.fetchedChangesTotal ?? 0
            guard await performStart(force: false, container: container, generation: generation),
                  isActive(generation),
                  let sync else { return .failed }
            // A service built or restarted by this run pulled before the remote change below.
            let fetchedByStart = sync.fetchedChangesTotal - (sync === existing ? fetchedBefore : 0)
            let outcome = await performRemoteChange(using: sync, generation: generation)
            return outcome == .noData && fetchedByStart > 0 ? .newData : outcome
        }
    }

    /// Detects an iCloud account switch and resets this container's checkpoints before any
    /// service exists for the new account (see `CloudKitSyncService.resetPersistedState`).
    /// Resolved once per controller lifecycle; a probe failure stays conservative — no reset.
    private func reconcileAccountIdentity(container: ContainerHandle, generation: UInt64) async {
        guard cachedAccountIdentity == nil else { return }
        let identity: String
        do {
            identity = try await container.userRecordID().recordName
        } catch {
            return
        }
        guard isActive(generation) else { return }

        if let previous = syncDefaults.string(forKey: Self.accountIdentityDefaultsKey),
           previous != identity {
            sync?.stop()
            sync = nil
            syncStarted = false
            CloudKitSyncService.resetPersistedState(
                containerIdentifier: Self.containerID,
                defaults: syncDefaults
            )
            clipStoreLog.info("iCloud account changed; reset CloudKit sync checkpoints.")
        }
        syncDefaults.set(identity, forKey: Self.accountIdentityDefaultsKey)
        cachedAccountIdentity = identity
    }

    /// A launch that found the history file missing (a fresh device, or one restored from a
    /// backup that left history out) left a marker. The change token in the always-backed-up
    /// preferences may claim the history was already downloaded, so drop only that token and the
    /// next pull refills from iCloud. Push receipts, the upload watermark, the quarantine and the
    /// encryption rollout state stay. The marker survives until this runs, so a clip captured
    /// meanwhile cannot defeat it. A service is stopped first because it holds the token in memory.
    private func restartPullPositionIfHistoryWasMissing() {
        guard syncDefaults.bool(forKey: ClipStore.pullPositionRestartPendingKey) else { return }
        sync?.stop()
        sync = nil
        syncStarted = false
        CloudKitSyncService.resetPullPosition(
            containerIdentifier: Self.containerID,
            defaults: syncDefaults
        )
        syncDefaults.removeObject(forKey: ClipStore.pullPositionRestartPendingKey)
        clipStoreLog.info("Restarting iCloud download position: history file was missing at launch")
    }

    private func performStart(
        force: Bool,
        container: ContainerHandle,
        generation: UInt64
    ) async -> Bool {
        guard isActive(generation) else { return false }
        if sync != nil, syncStarted, !force { return true }
        let service = sync ?? makeService(container.database, store, settingsBridge)
        guard isActive(generation) else { return false }
        sync = service
        let result = await service.start()
        guard isActive(generation), sync === service else { return false }
        switch result {
        case .started:
            syncStarted = true
            return true
        case .failed:
            // `start()` already reported the typed failure on the store.
            syncStarted = false
            return false
        }
    }

    /// Schedules one retry of `request` after a transient account status. No-op if the controller
    /// stopped, sync got disabled, or another operation already ran before the delay elapses —
    /// that operation already reflects current account state, so a stale retry would only duplicate work.
    private func scheduleTransientRetry(request: Request, generation: UInt64) {
        transientRetryTask?.cancel()
        let sequenceAtSchedule = operationSequence
        let delay = transientRetryDelayNanoseconds
        transientRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            guard self.isActive(generation), self.operationSequence == sequenceAtSchedule else {
                return
            }
            _ = await self.run(request, isTransientRetryAttempt: true)
        }
    }

    private func performRemoteChange(
        using service: CloudKitSyncService,
        generation: UInt64
    ) async -> IOSSyncRunOutcome {
        guard isActive(generation), sync === service else { return .failed }
        let outcome = await service.handleRemoteChangeOutcome()
        guard isActive(generation), sync === service else { return .failed }
        switch outcome {
        case .newData: return .newData
        case .noData: return .noData
        case .failed: return .failed
        }
    }

    private func isActive(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation && settings.syncEnabled && !Task.isCancelled
    }

    nonisolated static func accountDecision(
        for status: CKAccountStatus
    ) -> IOSCloudAccountDecision {
        switch status {
        case .available:
            .proceed
        case .noAccount:
            .hardUnavailable(reason: .notAuthenticated)
        case .restricted:
            .restricted
        case .temporarilyUnavailable, .couldNotDetermine:
            .transient(SyncFailure(kind: .accountUnavailable))
        @unknown default:
            .proceed
        }
    }

    private func tearDownService(
        status: UnavailableStatus,
        generation: UInt64
    ) {
        guard isActive(generation) else { return }
        sync?.stop()
        sync = nil
        syncStarted = false
        unregisterForRemoteNotifications()
        switch status {
        case .unavailable(let reason):
            store.markSyncUnavailable(reason: reason)
        case .failed(let failure):
            store.markClipsWaiting([])
            store.markSyncFailure(failure)
        }
    }

    private static func makeLiveRecoveryTriggers(
        onNetworkRestored: @escaping @MainActor () -> Void,
        onAccountChanged: @escaping @MainActor () -> Void
    ) -> SyncRecoveryTriggers? {
        guard CloudContainerProvisioning.isProvisioned(for: containerID) else { return nil }
        return SyncRecoveryTriggers(
            container: CKContainer(identifier: containerID),
            onNetworkRestored: onNetworkRestored,
            onAccountChanged: onAccountChanged
        )
    }

    private static func makeLiveContainer() -> ContainerHandle? {
        guard CloudContainerProvisioning.isProvisioned(for: containerID) else { return nil }
        let container = CKContainer(identifier: containerID)
        return ContainerHandle(
            database: container.privateCloudDatabase,
            accountStatus: { try await container.accountStatus() },
            userRecordID: { try await container.userRecordID() }
        )
    }
}

@main
struct YankApp: App {
    @UIApplicationDelegateAdaptor(YankAppDelegate.self) private var appDelegate
    @State private var store: ClipStore
    @State private var settings: IOSSettings
    @State private var syncController: IOSCloudSyncController
    @State private var foregroundCaptureDisclosureSession: IOSForegroundCaptureDisclosureSession
    @State private var pasteAccess: PasteAccessMonitor
    @State private var historyOpenRequest = 0
    /// The clip a tapped Spotlight result asked for; the history list opens it once readable.
    @State private var requestedClipID: UUID?
    /// SwiftUI reports a return from the background as `.background`, `.inactive`, `.active`,
    /// so the handler remembers the visit instead of comparing with the previous phase.
    @State private var wasInBackground = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let runtime = IOSAppRuntime.shared
        _foregroundCaptureDisclosureSession = State(initialValue: IOSForegroundCaptureDisclosureSession())
        _pasteAccess = State(initialValue: PasteAccessMonitor())
        _store = State(initialValue: runtime.store)
        _settings = State(initialValue: runtime.settings)
        _syncController = State(initialValue: runtime.syncController)
    }

    private var spotlightEnabled: Bool {
        settings.spotlightIndexing
    }

    var body: some Scene {
        WindowGroup {
            HistoryView(
                store: store,
                settings: settings,
                iCloudSignedOut: syncController.iCloudSignedOut,
                onRetrySync: { await syncController.start(force: true) },
                onKeepLocalOnly: { syncController.keepLocalOnly(clipIDs: $0) },
                onReviewCaptureMethods: {
                    foregroundCaptureDisclosureSession.beginReview(mode: settings.foregroundCaptureMode)
                },
                pasteAccess: pasteAccess,
                openRequest: historyOpenRequest,
                requestedClipID: $requestedClipID
            )
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let clipID = SpotlightActivity.clipID(from: activity) else { return }
                    // The first-run screen sits above the list; the clip opens behind it otherwise.
                    if foregroundCaptureDisclosureSession.activeSections != nil { closeFirstRunScreen() }
                    requestedClipID = clipID
                }
                .sheet(item: Binding(
                    get: { foregroundCaptureDisclosureSession.activeSections },
                    set: { sections in
                        if sections == nil { closeFirstRunScreen() }
                    }
                )) { sections in
                    FirstRunSetupView(
                        sections: sections,
                        settings: settings,
                        onFinish: { finishedSetup in
                            if finishedSetup { settings.completeCaptureSetup() }
                            closeFirstRunScreen()
                        }
                    )
                }
                .tint(settings.theme.foreground)
                .task {
                    pasteAccess.beginVisit()
                    // The list shows a loading state until the saved history has been read.
                    await IOSAppRuntime.shared.hydrate()
                    // Needs the history read: set-up counts as finished when clips already exist.
                    foregroundCaptureDisclosureSession.beginAutomatically(
                        mode: settings.foregroundCaptureMode,
                        captureSetupCompleted: settings.captureSetupCompleted,
                        syncEnabled: settings.syncEnabled,
                        syncAvailable: CloudContainerProvisioning.isProvisioned(for: IOSCloudSyncController.containerID)
                    )
                    await refreshForeground()
                    await refreshSpotlightIndex()
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if oldPhase == .active && newPhase != .active {
                        appDelegate.flushHistoryWhenLeavingActive {
                            try await store.flushPendingWritesBeforeSuspension()
                        }
                    }
                    if newPhase == .background {
                        wasInBackground = true
                    }
                    if newPhase == .active {
                        let returnedFromBackground = wasInBackground
                        wasInBackground = false
                        if returnedFromBackground { pasteAccess.beginVisit() }
                        // Folders an extension created while the app was away are not marked yet.
                        store.reconcileBackupExclusionInBackground()
                        Task {
                            await refreshForeground()
                            await refreshSpotlightIndex()
                            if returnedFromBackground {
                                historyOpenRequest &+= 1
                            }
                        }
                    }
                }
                .onChange(of: settings.syncEnabled) { _, enabled in
                    if enabled {
                        Task { await syncController.start() }
                    } else {
                        syncController.stop()
                        appDelegate.disableRemoteChanges()
                    }
                }
                .onChange(of: settings.includeHistoryInBackups) {
                    store.reconcileBackupExclusionInBackground()
                }
                .onChange(of: settings.foregroundCaptureMode) { oldMode, newMode in
                    if newMode == .undecided {
                        foregroundCaptureDisclosureSession.deferForCurrentSession()
                    }
                    pasteAccess.reset()
                    Task {
                        await IOSForegroundRefreshPipeline.refreshAfterModeChange(
                            from: oldMode,
                            to: newMode,
                            refresh: { await refreshForeground() }
                        )
                    }
                }
                .onChange(of: store.contentRevision) {
                    if !store.items.isEmpty && !settings.captureSetupCompleted {
                        settings.completeCaptureSetup()
                    }
                    if spotlightEnabled { SpotlightIndexer.schedule(store.items) }
                }
        }
    }

    private func closeFirstRunScreen() {
        foregroundCaptureDisclosureSession.end()
        foregroundCaptureDisclosureSession.deferForCurrentSession()
    }

    private func refreshForeground() async {
        // A launch before the first unlock leaves the history unread; the files are readable now.
        IOSAppRuntime.shared.recoverProtectedStorage()
        await IOSForegroundRefreshPipeline.refresh(
            currentMode: { settings.foregroundCaptureMode },
            drainExplicitCaptures: { await store.drainShareInbox() },
            recordSuccessfulCaptureMethods: {
                settings.recordSuccessfulCaptureMethods(from: $0)
            },
            captureAutomatically: { await refreshAutomaticPasteboard() },
            refreshSync: { await syncController.refreshForeground() }
        )
        // Nothing runs in the background, so a clip that aged past the window while the app was
        // away is only removed when it returns. After the pull: a clip another device used again
        // meanwhile must not be tombstoned from the stale local copy.
        store.enforceRetentionAndLimit()
    }

    private func refreshAutomaticPasteboard() async {
        guard settings.foregroundCaptureMode == .automatic else { return }
        let pasteboard = UIPasteboard.general
        let pasteboardChangeCount = pasteboard.changeCount
        let pasteboardTypes = pasteboard.types
        await IOSForegroundRefreshCoordinator.shared.processPasteboard(
            pasteboardChangeCount: pasteboardChangeCount,
            pasteboardTypes: pasteboardTypes,
            isAutomaticCaptureAuthorized: {
                settings.foregroundCaptureMode == .automatic
            },
            currentPasteboardChangeCount: { pasteboard.changeCount },
            isPasteboardOwnedByThisInstallation: {
                store.pasteboardHasMatchingOriginTag(
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    pasteboardTypes: pasteboardTypes,
                    readData: { pasteboard.data(forPasteboardType: $0) }
                )
            },
            readText: {
                let text = pasteboard.string
                if text == nil {
                    pasteAccess.recordEmptyRead(declaredTypes: pasteboardTypes)
                } else {
                    pasteAccess.recordSuccessfulRead()
                }
                return text
            },
            capture: { text, generation, hasRichContent in
                await store.captureForegroundText(
                    text,
                    pasteboardGeneration: generation,
                    hasRichContent: hasRichContent
                )
            }
        )
    }

    /// Waits for the saved history: reconciling against an unloaded store would clear the whole
    /// Yank Spotlight domain.
    private func refreshSpotlightIndex() async {
        await store.hydrate()
        if spotlightEnabled {
            SpotlightIndexer.index(store.items)
        } else {
            // A scoped clear is safe to retry and removes stale Yank results left by a
            // previously failed deletion or a prior app process.
            SpotlightIndexer.clear()
        }
    }

}
