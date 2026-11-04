import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

let syncLog = Logger(subsystem: "com.thepatientzero.yank", category: "sync")

// `SyncableStore` lives in `Sources/YankCore/SyncableStore.swift` (no CloudKit import) so
// the iOS extensions can use the store without linking CloudKit.

enum CloudKitSyncError: LocalizedError {
    case missingBlobAsset(String)
    case partialRecordFailures(Int)
    case partialRecordSaves(Int, SyncFailure? = nil)
    case unrecoverableLocalRecords(Int)
    case backfillDidNotConverge(Int)
    case pushReceiptEncodingFailed
    case changeTokenEncodingFailed
    case pullQuarantineEncodingFailed
    case pullQuarantineOverflow
    case encryptedDataKeyReset

    var errorDescription: String? {
        switch self {
        case .missingBlobAsset(let filename):
            "Synced blob \(filename) is missing from CloudKit. Sync will retry."
        case .partialRecordFailures(let count):
            "CloudKit could not return \(count) changed record(s). Sync will retry."
        case .partialRecordSaves(let count, _):
            "CloudKit could not save \(count) record(s). Sync will retry."
        case .unrecoverableLocalRecords(let count):
            "Backfill stopped before upload because \(count) local record(s) are missing required blob data."
        case .backfillDidNotConverge(let count):
            "Backfill finished uploading, but \(count) local record(s) are still missing from CloudKit."
        case .pushReceiptEncodingFailed:
            "CloudKit push acknowledgements could not be saved. Sync will safely replay."
        case .changeTokenEncodingFailed:
            "Where sync stopped could not be saved. Sync will safely replay."
        case .pullQuarantineEncodingFailed:
            "Skipped CloudKit records could not be recorded. Sync will safely replay."
        case .pullQuarantineOverflow:
            "Too many skipped CloudKit records are awaiting recovery. Sync will retry."
        case .encryptedDataKeyReset:
            "iCloud's encrypted data key was reset. Yank is uploading your clips again."
        }
    }

    /// What the apps show: the classified cause when a save recorded one, otherwise this
    /// error's own sentence.
    var failure: SyncFailure {
        if case .partialRecordSaves(_, let cause?) = self { return cause }
        return SyncFailure(kind: .other, detail: errorDescription)
    }
}

public struct CloudKitBackfillResult: Equatable, Sendable {
    public let localRecordCount: Int
    public let presentRecordCountBefore: Int
    public let missingRecordCountBefore: Int
    public let uploadedRecordCount: Int
    public let presentRecordCountAfter: Int
    public let remainingMissingRecordCount: Int

    public var converged: Bool {
        remainingMissingRecordCount == 0
    }
}

/// What one remote-change run did, for callers that report it to the system.
enum CloudKitRemoteChangeOutcome: Equatable, Sendable {
    /// The run fetched changes from CloudKit.
    case newData
    /// The run succeeded and fetched nothing.
    case noData
    case failed
}

/// Syncs the local store with the user's CloudKit private database.
/// Offline-first: the local store is the source of truth, CloudKit the transport.
/// Conflicts resolve through `ClipboardMerge` (last-writer-wins); deletes propagate via tombstones.
@MainActor
public final class CloudKitSyncService {
    let database: any CloudKitDatabase
    let zoneID = CKRecordZone.ID(zoneName: "YankZone", ownerName: CKCurrentUserDefaultName)
    let devicesZoneID = CKRecordZone.ID(
        zoneName: CloudKitDeviceRegistry.zoneName,
        ownerName: CKCurrentUserDefaultName
    )
    private let subscriptionID = "yank-changes"
    let defaults: UserDefaults
    let rolloutState: EncryptionRolloutState
    private let tokenKey: String
    private let pushWatermarkKey: String
    private let pushReceiptsKey: String
    private let pullQuarantineKey: String
    let encryptedCopyBackfillKey: String
    private let historyCoverageKey: String
    private let localOnlyClipsKey: String
    private let pushDebounceNanoseconds: UInt64
    private let pushRetryDelaysNanoseconds: [UInt64]
    private let beforeReceiptPersistence: (() throws -> Void)?
    private let afterReceiptInvalidationBeforeTokenPersistence: (() throws -> Void)?
    weak var store: SyncableStore?
    /// Weak like `store`: the composition root owns the settings bridge and outlives the
    /// service, so a strong edge here would keep the app's settings graph alive past `stop()`.
    private weak var settingsStore: (any SyncedSettingsStore)?
    var changeToken: CKServerChangeToken?
    private var pushReceipts: [UUID: Date]?
    private var pullQuarantine: [String: CloudKitPullQuarantineEntry]
    /// Whether the settings record is worth a round trip on the next push. Purely an
    /// optimisation — the fetch-first reconcile decides by stamp, never by this flag — so a
    /// change made while sync was down is still published by the next `start()`.
    private var settingsReconciliationPending = false
    /// Set when any CloudKit surface reports that the user reset their encrypted-data key;
    /// cleared by `recoverFromEncryptedDataKeyReset`.
    private var encryptedDataKeyResetPending = false
    private var localChangeObserver: NSObjectProtocol?
    private var settingsChangeObserver: NSObjectProtocol?
    private var scheduledPush: Task<Void, Never>?
    private var pushRetry: Task<Void, Never>?
    private var pushRetryAttempt = 0
    private var activePush: (id: UUID, task: Task<Void, Error>)?
    /// True while a pull waits for its snapshot to reach the disk; pushes wait for it to clear.
    private var durablePullApplyInFlight = false
    private var durablePullApplyWaiters: [CheckedContinuation<Void, Never>] = []
    private var activePull: PullFlight?
    /// Changes every pull of this service fetched so far; a caller that cannot see a pull's own
    /// count (the start) compares it before and after.
    private(set) var fetchedChangesTotal = 0
    /// Pull requests made so far; a running pull serves the ones made before it started.
    private var pullRequestCount: UInt64 = 0
    /// A caller asked for a pull that fetches changes since the last pull started.
    private var changePullRequested = false
    private var lifecycleGeneration: UInt64 = 0
    private var isStopped = false
    /// The clips the last push that got past preparing could not upload.
    private var waitingClips: [SyncWaitingClip] = []

    // Encryption rollout. `rolloutDeviceID` stays nil until the app opts in, which keeps the
    // service dual-writing and silent about devices (the safe default for SwiftPM users).
    var rolloutDeviceID: String?
    weak var encryptionStatusReporter: (any SyncEncryptionStatusReporting)?
    var lastRolloutEvaluation: Date?
    var rolloutReevaluationRequested = false
    var activeRolloutEvaluation: (id: UUID, task: Task<Void, Never>)?
    var activeSweep: (id: UUID, task: Task<Void, Never>)?
    var loggedBlankClipIDs: Set<UUID> = []

    /// Live entry point: binds to the container's private database. `CKContainer(identifier:)`
    /// hard-traps on a binary not provisioned for the container, so callers must gate on
    /// provisioning before constructing the service (see `AppDelegate`).
    public convenience init(
        containerIdentifier: String,
        store: SyncableStore,
        settingsStore: (any SyncedSettingsStore)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            containerIdentifier: containerIdentifier,
            store: store,
            database: Self.liveDatabase(for: containerIdentifier),
            settingsStore: settingsStore,
            defaults: defaults
        )
    }

    private static func liveDatabase(for containerIdentifier: String) -> any CloudKitDatabase {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        #if DEBUG
        var wrapped: any CloudKitDatabase = database
        if KeyResetInjectingDatabase.isRequested {
            wrapped = KeyResetInjectingDatabase(wrapping: wrapped)
        }
        if DebugRolloutOverrides.simulateDeviceZoneFailure {
            wrapped = DeviceZoneFailureInjectingDatabase(wrapping: wrapped)
        }
        return wrapped
        #else
        return database
        #endif
    }

    /// Discards every persisted sync checkpoint (token, receipts, watermark, quarantine, epoch, history coverage)
    /// for a container. They describe the previous iCloud account's zone, and keeping them would
    /// suppress re-uploading the library into a new one. Call before constructing a fresh service.
    public static func resetPersistedState(
        containerIdentifier: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: "cloudkit.changeToken.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.lastPushedModifiedAt.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.pushReceipts.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.pullQuarantine.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.pullQuarantine.epoch.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.encryptedCopyBackfill.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.historyCoverage.\(containerIdentifier)")
        defaults.removeObject(forKey: "cloudkit.localOnlyClips.\(containerIdentifier)")
        EncryptionRolloutState.reset(containerIdentifier: containerIdentifier, defaults: defaults)
    }

    /// Forgets only where the last pull stopped, so the next pull reads the zone from the start.
    /// For a device whose local history is gone (for example restored from a backup that left it
    /// out) while its preferences, and the position in them, came back. Pulling from the start is
    /// safe against clips and deletions already on the device. Push receipts, the upload
    /// watermark, the quarantine and the encryption rollout state are kept. Call before
    /// constructing the service, which reads the token once in `init`.
    public static func resetPullPosition(
        containerIdentifier: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: "cloudkit.changeToken.\(containerIdentifier)")
    }

    /// Seam-injecting initializer — tests pass an in-memory `CloudKitDatabase` fake.
    init(
        containerIdentifier: String,
        store: SyncableStore,
        database: any CloudKitDatabase,
        settingsStore: (any SyncedSettingsStore)? = nil,
        defaults: UserDefaults = .standard,
        pushDebounceNanoseconds: UInt64 = 750_000_000,
        pushRetryDelaysNanoseconds: [UInt64] = CloudKitSyncService.defaultPushRetryDelaysNanoseconds,
        resolutionEpoch: String = CloudKitSyncService.defaultResolutionEpoch,
        beforeReceiptPersistence: (() throws -> Void)? = nil,
        afterReceiptInvalidationBeforeTokenPersistence: (() throws -> Void)? = nil
    ) {
        self.database = database
        self.store = store
        self.settingsStore = settingsStore
        self.defaults = defaults
        self.rolloutState = EncryptionRolloutState(defaults: defaults, containerIdentifier: containerIdentifier)
        self.tokenKey = "cloudkit.changeToken.\(containerIdentifier)"
        self.pushWatermarkKey = "cloudkit.lastPushedModifiedAt.\(containerIdentifier)"
        self.pushReceiptsKey = "cloudkit.pushReceipts.\(containerIdentifier)"
        self.pullQuarantineKey = "cloudkit.pullQuarantine.\(containerIdentifier)"
        self.encryptedCopyBackfillKey = "cloudkit.encryptedCopyBackfill.\(containerIdentifier)"
        self.historyCoverageKey = "cloudkit.historyCoverage.\(containerIdentifier)"
        self.localOnlyClipsKey = "cloudkit.localOnlyClips.\(containerIdentifier)"
        self.pushDebounceNanoseconds = pushDebounceNanoseconds
        self.pushRetryDelaysNanoseconds = pushRetryDelaysNanoseconds
        self.beforeReceiptPersistence = beforeReceiptPersistence
        self.afterReceiptInvalidationBeforeTokenPersistence =
            afterReceiptInvalidationBeforeTokenPersistence
        self.changeToken = Self.loadToken(from: defaults, key: tokenKey)
        self.pushReceipts = Self.loadPushReceipts(from: defaults, key: pushReceiptsKey)
        self.pullQuarantine = Self.reQuarantineForEpoch(
            Self.loadPullQuarantine(from: defaults, key: pullQuarantineKey),
            epoch: resolutionEpoch,
            defaults: defaults,
            quarantineKey: pullQuarantineKey,
            epochKey: "cloudkit.pullQuarantine.epoch.\(containerIdentifier)"
        )
    }

    // `isolated deinit` runs cleanup on the main actor (the runtime hops if the last release lands
    // off-main), so it never traps the way `MainActor.assumeIsolated` would — important here, since
    // this service is captured by its own async start/push tasks and can be released off-main.
    isolated deinit {
        stop()
    }

    /// Permanently stops this service instance. Re-enabling sync creates a fresh service.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        lifecycleGeneration &+= 1
        scheduledPush?.cancel()
        scheduledPush = nil
        cancelPushRetry()
        pushRetryAttempt = 0
        activePush?.task.cancel()
        activePush = nil
        activePull?.task.cancel()
        activePull = nil
        activeRolloutEvaluation?.task.cancel()
        activeRolloutEvaluation = nil
        activeSweep?.task.cancel()
        activeSweep = nil
        if let localChangeObserver {
            NotificationCenter.default.removeObserver(localChangeObserver)
            self.localChangeObserver = nil
        }
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
            self.settingsChangeObserver = nil
        }
    }

    /// Mark sync as unavailable on the store (e.g. no iCloud account, container not provisioned),
    /// without attempting a network round-trip.
    public func reportUnavailable(reason: SyncStatus.Reason) {
        guard !isStopped else { return }
        store?.markSyncUnavailable(reason: reason)
    }

    /// Records a failure on the store as one plain sentence, keeping CloudKit's own text in the
    /// log for diagnosis. A store that does not adopt `SyncIssueReporting` gets the same sentence
    /// through `markSyncFailed(_:)`.
    @discardableResult
    private func reportFailure(_ error: any Error, during phase: String) -> SyncFailure {
        let failure = CloudKitSyncFailureClassifier.classify(error)
        syncLog.error("\(phase, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        if let reporter = store as? any SyncIssueReporting {
            reporter.markSyncFailure(failure)
        } else {
            store?.markSyncFailed(failure.message)
        }
        return failure
    }

    private func reportWaitingClips(_ clips: [SyncWaitingClip]) {
        waitingClips = clips
        (store as? any SyncIssueReporting)?.markClipsWaiting(clips)
    }

    /// Stops waiting for these clips: they stay on this device and are not uploaded unless they
    /// are edited. Meant for clips listed as waiting; ids that are not live clips are ignored.
    public func keepLocalOnly(clipIDs: [UUID]) {
        guard let store else { return }
        let requested = Set(clipIDs)
        let live = store.itemsForSync().filter { requested.contains($0.id) }
        var kept = CloudKitLocalOnlyClips.load(from: defaults, key: localOnlyClipsKey)
        kept.keep(live)
        kept.persist(to: defaults, key: localOnlyClipsKey)
        guard !isStopped else { return }
        reportWaitingClips(waitingClips.filter { !requested.contains($0.id) })
    }

    /// Clips to leave out of an upload because the user chose to keep them on this device.
    /// Entries for clips that were edited or removed since lapse here.
    private func itemsNotKeptLocalOnly(_ items: [ClipboardItem], among local: [ClipboardItem]) -> [ClipboardItem] {
        var kept = CloudKitLocalOnlyClips.load(from: defaults, key: localOnlyClipsKey)
        guard !kept.isEmpty else { return items }
        if kept.prune(against: local) {
            kept.persist(to: defaults, key: localOnlyClipsKey)
        }
        return items.filter { !kept.isKept($0) }
    }

    /// One-shot bring-up: ensure zone + push subscription, pull remote, push local.
    @discardableResult
    public func start() async -> CloudKitSyncStartResult {
        guard let generation = activeGeneration else {
            return .failed(message: Self.stoppedMessage)
        }
        do {
            try requireActive(generation)
            store?.markSyncStarted()
            try await ensureZone()
            try requireActive(generation)
            try await ensureSubscription()
            try requireActive(generation)
            // Bring-up always reconciles the settings record, which is what recovers a record
            // an earlier build could not read and one this device never managed to publish.
            settingsReconciliationPending = true
            try await prepareBlankRepairIfNeeded(generation: generation)
            try scheduleEncryptedCopyBackfillIfNeeded(generation: generation)
            try await coalescedPull(generation: generation)
            try requireActive(generation)
            // Before observers and the first push, so nothing is built in the wrong write mode.
            try await reconcileEncryptionRollout(generation: generation)
            try startObservingLocalChanges(generation: generation)
            try startObservingSettingsChanges(generation: generation)
            try await pushLocal(generation: generation)
            try requireActive(generation)
            // The push may have adopted a newer settings record the pull did not carry.
            try await coalescedPull(generation: generation, fetchesChanges: false)
            store?.markSyncSucceeded(at: Date())
            return .started
        } catch {
            guard shouldReport(error, generation: generation) else {
                return .failed(message: CloudKitSyncFailureClassifier.classify(error).message)
            }
            // Keep listening even though bring-up failed: local edits must still schedule
            // pushes once the transport recovers.
            try? startObservingLocalChanges(generation: generation)
            try? startObservingSettingsChanges(generation: generation)
            let failure = reportFailure(error, during: "start")
            return .failed(message: failure.message)
        }
    }

    /// One-time UUID-preserving recovery for historical local records that CloudKit never
    /// accepted. Presence checks fetch record metadata only, existing records are never
    /// updated or deleted, and ordinary incremental push receipts are left untouched.
    public func backfillMissingLocalRecords(dryRun: Bool = false) async throws -> CloudKitBackfillResult {
        guard let generation = activeGeneration else { throw CancellationError() }
        try requireActive(generation)
        guard let store else {
            return CloudKitBackfillResult(
                localRecordCount: 0,
                presentRecordCountBefore: 0,
                missingRecordCountBefore: 0,
                uploadedRecordCount: 0,
                presentRecordCountAfter: 0,
                remainingMissingRecordCount: 0
            )
        }

        let localItems = store.itemsForSync()
        let localRecordNames = localItems.map { $0.id.uuidString }
        let before = try await fetchRecordPresence(for: localRecordNames, generation: generation)
        try requireActive(generation)
        let missingItems = itemsNotKeptLocalOnly(
            localItems.filter { before.missingRecordNames.contains($0.id.uuidString) },
            among: localItems
        )
        let prepared = Self.preparePushRecords(missingItems, in: zoneID, policy: plainContentPolicy) { item in
            item.isDeleted ? nil : existingBlobURL(for: item)
        }
        guard prepared.skippedItemIDs.isEmpty else {
            throw CloudKitSyncError.unrecoverableLocalRecords(prepared.skippedItemIDs.count)
        }

        if !dryRun {
            try requireActive(generation)
            try await savePreparedRecords(prepared.records, generation: generation)
        }

        let after = dryRun
            ? before
            : try await fetchRecordPresence(for: localRecordNames, generation: generation)
        try requireActive(generation)
        if !dryRun, !after.missingRecordNames.isEmpty {
            throw CloudKitSyncError.backfillDidNotConverge(after.missingRecordNames.count)
        }

        return CloudKitBackfillResult(
            localRecordCount: localItems.count,
            presentRecordCountBefore: before.presentRecordNames.count,
            missingRecordCountBefore: before.missingRecordNames.count,
            uploadedRecordCount: dryRun ? 0 : prepared.records.count,
            presentRecordCountAfter: after.presentRecordNames.count,
            remainingMissingRecordCount: after.missingRecordNames.count
        )
    }

    private func startObservingLocalChanges(generation: UInt64) throws {
        try requireActive(generation)
        guard localChangeObserver == nil else { return }
        localChangeObserver = NotificationCenter.default.addObserver(
            forName: .yankLocalStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.requireActive(generation)
                    try self.schedulePush(generation: generation)
                } catch {
                    // A queued notification from a stopped generation is intentionally ignored.
                }
            }
        }
    }

    /// Observes local settings choices directly, exactly as the clip path observes local store
    /// changes — so no composition root has to relay them. Only a *choice* posts this; an
    /// adopted value stays silent and cannot bounce back at the device it came from.
    private func startObservingSettingsChanges(generation: UInt64) throws {
        try requireActive(generation)
        guard settingsChangeObserver == nil else { return }
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .yankSyncedSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.requireActive(generation)
                    self.settingsReconciliationPending = true
                    try self.schedulePush(generation: generation)
                    // A lowered limit trims this device at once and is recorded; a raised one
                    // refetches the clips that trimming dropped, even when the zone has no news.
                    if self.historyLimitRoseAboveCoverage() {
                        await self.handleRemoteChange()
                    }
                } catch {
                    // Same as the local-change observer above: ignore it.
                }
            }
        }
    }

    /// Called from the silent push handler to fold in remote changes.
    @discardableResult
    public func handleRemoteChange() async -> Bool {
        await handleRemoteChangeOutcome() != .failed
    }

    /// Like `handleRemoteChange()`, and says whether the run fetched anything, which is what
    /// iOS wants to hear after a background push.
    func handleRemoteChangeOutcome() async -> CloudKitRemoteChangeOutcome {
        guard let generation = activeGeneration else { return .failed }
        do {
            try requireActive(generation)
            let fetched = try await coalescedPull(generation: generation)
            try requireActive(generation)
            try await reconcileEncryptionRollout(generation: generation)
            // Receipt comparison makes this a no-op for a clean pull. Always reconsidering
            // local state is what lets an ordinary remote change repair a missing CKAsset.
            try await pushLocal(generation: generation)
            try requireActive(generation)
            // The push may have adopted a newer settings record the pull did not carry.
            try await coalescedPull(generation: generation, fetchesChanges: false)
            store?.markSyncSucceeded(at: Date())
            return fetched > 0 ? .newData : .noData
        } catch {
            guard shouldReport(error, generation: generation) else { return .failed }
            reportFailure(error, during: "remote pull")
            return .failed
        }
    }

    private func schedulePush(generation: UInt64) throws {
        try requireActive(generation)
        scheduledPush?.cancel()
        // A fresh trigger supersedes any backoff still waiting from an earlier failure.
        cancelPushRetry()
        pushRetryAttempt = 0
        let debounceNanoseconds = pushDebounceNanoseconds
        scheduledPush = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                guard let self else { return }
                try self.requireActive(generation)
                try await self.pushLocal(generation: generation)
                try self.requireActive(generation)
                self.store?.markSyncSucceeded(at: Date())
            } catch {
                guard let self, self.shouldReport(error, generation: generation) else { return }
                self.reportFailure(error, during: "local push")
                self.schedulePushRetry(after: error, generation: generation)
            }
        }
    }

    /// Advances the bounded backoff chain after a failed push. Without it a transient CloudKit
    /// failure parks the pending records until the next local change or app launch.
    private func schedulePushRetry(after error: any Error, generation: UInt64) {
        guard canMutate(generation) else { return }
        guard pushRetryAttempt < pushRetryDelaysNanoseconds.count else {
            syncLog.error("local push retries exhausted; waiting for the next sync trigger")
            return
        }
        let delayNanoseconds = Self.pushRetryDelayNanoseconds(
            for: error,
            fallback: pushRetryDelaysNanoseconds[pushRetryAttempt]
        )
        pushRetryAttempt += 1
        let attempt = pushRetryAttempt
        pushRetry = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                guard let self else { return }
                // This attempt is no longer pending, so a failure can arm the next one.
                self.pushRetry = nil
                try self.requireActive(generation)
                syncLog.info("retrying local push (attempt \(attempt, privacy: .public))")
                try await self.pushLocal(generation: generation)
                try self.requireActive(generation)
                self.pushRetryAttempt = 0
                self.store?.markSyncSucceeded(at: Date())
            } catch {
                guard let self, self.shouldReport(error, generation: generation) else { return }
                self.reportFailure(error, during: "local push retry")
                self.schedulePushRetry(after: error, generation: generation)
            }
        }
    }

    private func cancelPushRetry() {
        pushRetry?.cancel()
        pushRetry = nil
    }

    /// CloudKit's own `retryAfterSeconds` hint wins over the local backoff step when present,
    /// clamped so a nonsensical server value cannot park the chain (or trap the conversion).
    nonisolated static func pushRetryDelayNanoseconds(
        for error: any Error,
        fallback: UInt64
    ) -> UInt64 {
        guard let seconds = retryAfterSeconds(from: error), seconds.isFinite, seconds > 0 else {
            return fallback
        }
        let requested = seconds * 1_000_000_000
        guard requested < Double(maximumPushRetryDelayNanoseconds) else {
            return maximumPushRetryDelayNanoseconds
        }
        return UInt64(requested)
    }

    private nonisolated static func retryAfterSeconds(from error: any Error) -> Double? {
        if let cloudKitError = error as? CKError {
            return cloudKitError.retryAfterSeconds
        }
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return nil }
        return nsError.userInfo[CKErrorRetryAfterKey] as? Double
    }

    nonisolated static let defaultPushRetryDelaysNanoseconds: [UInt64] = [
        5_000_000_000,
        30_000_000_000,
        120_000_000_000
    ]

    private nonisolated static let maximumPushRetryDelayNanoseconds: UInt64 = 3_600_000_000_000

    private func ensureZone() async throws {
        try await database.ensureZone(zoneID)
    }

    private func ensureSubscription() async throws {
        try await database.ensureSubscription(id: subscriptionID)
    }

    /// One running pull and the requests it was started for.
    private struct PullFlight {
        let id: UUID
        let task: Task<Int, Error>
        /// The pull serves every request made up to the moment it started.
        let servesRequestsThrough: UInt64
        /// False when the pull only runs the history-limit refetch.
        let fetchesChanges: Bool
    }

    /// Runs a pull with at most one in flight. A caller that arrives meanwhile waits for it and
    /// then for one follow-up pull that every caller waiting before it started shares; a caller
    /// that arrives while the follow-up runs asks for one more. A pull that failed for an earlier
    /// caller does not fail the later ones; their pull reports its own result. Returns the
    /// changes fetched by the pulls this caller waited on. `fetchesChanges: false` is for the
    /// history-limit refetch alone, which a pull that fetches changes also covers.
    @discardableResult
    private func coalescedPull(generation: UInt64, fetchesChanges: Bool = true) async throws -> Int {
        try requireActive(generation)
        pullRequestCount &+= 1
        let request = pullRequestCount
        if fetchesChanges { changePullRequested = true }
        var fetched = 0
        while true {
            try requireActive(generation)
            let flight = activePull ?? startPullFlight(generation: generation)
            let result = await flight.task.result
            let servesRequest = flight.servesRequestsThrough >= request
                && (flight.fetchesChanges || !fetchesChanges)
            switch result {
            case .success(let count):
                fetched += count
                if servesRequest { return fetched }
            case .failure(let error):
                if servesRequest { throw error }
            }
        }
    }

    private func startPullFlight(generation: UInt64) -> PullFlight {
        let id = UUID()
        let fetchesChanges = changePullRequested
        changePullRequested = false
        let task = Task { @MainActor [weak self] () throws -> Int in
            guard let self else { throw CancellationError() }
            defer { if self.activePull?.id == id { self.activePull = nil } }
            guard fetchesChanges else {
                return try await self.backfillIfHistoryLimitRose(generation: generation)
            }
            let recovered = try await self.pullRecoveringFromTokenLoss(generation: generation)
            let backfilled = try await self.backfillIfHistoryLimitRose(generation: generation)
            return recovered + backfilled
        }
        let flight = PullFlight(
            id: id,
            task: task,
            servesRequestsThrough: pullRequestCount,
            fetchesChanges: fetchesChanges
        )
        activePull = flight
        return flight
    }

    /// The history limit the settings store applies right now, or `nil` when there is no
    /// settings store or its preferences cannot be read.
    private var effectiveHistoryLimit: Int? {
        settingsStore?.syncedSettings?.historyLimit.rawValue
    }

    /// The lowest history limit this device has applied since its change token last started
    /// from nothing; the clips above it were trimmed here and are still in iCloud. A device from
    /// a build that predates the marker is assumed to have been trimmed to the default limit,
    /// which repairs devices that were already affected. `nil` while there is no token to
    /// describe, because the next pull starts from nothing and records the limit itself.
    private func historyCoverage() -> Int? {
        if let stored = defaults.object(forKey: historyCoverageKey) as? Int { return stored }
        return changeToken == nil ? nil : HistoryLimit.essential.rawValue
    }

    /// Records a limit this device has just applied. Never raises the marker: it only falls when
    /// the device trims further, and a pull that starts from nothing resets it explicitly.
    private func lowerHistoryCoverage(to limit: Int) {
        guard let coverage = historyCoverage(), limit < coverage else { return }
        defaults.set(limit, forKey: historyCoverageKey)
    }

    /// Lowers the marker to the effective limit, then reports whether the limit sits above what
    /// this device was last trimmed to.
    private func historyLimitRoseAboveCoverage() -> Bool {
        guard let limit = effectiveHistoryLimit else { return false }
        lowerHistoryCoverage(to: limit)
        guard let coverage = historyCoverage() else { return false }
        return limit > coverage
    }

    /// Fetches the zone again from the start once the history limit exceeds what this device was
    /// last trimmed to, so clips an earlier, lower limit dropped come back up to the new limit.
    /// Trimming never tombstones, so they are still in iCloud. Push receipts are kept: the
    /// refetch re-seeds them for the winners it re-delivers, and a full re-upload is not wanted.
    /// The restarted pull records the limit it applied, so this cannot repeat.
    private func backfillIfHistoryLimitRose(generation: UInt64) async throws -> Int {
        try requireActive(generation)
        guard historyLimitRoseAboveCoverage(),
              let limit = effectiveHistoryLimit,
              let coverage = historyCoverage() else { return 0 }
        syncLog.info(
            "history limit rose from \(coverage, privacy: .public) to \(limit, privacy: .public); refetching the zone from the start"
        )
        try persistToken(nil, generation: generation)
        changeToken = nil
        let fetched = try await pullUsingCurrentToken(generation: generation)
        try requireActive(generation)
        syncLog.info("history backfill finished under limit \(limit, privacy: .public)")
        return fetched
    }

    private func pullRecoveringFromTokenLoss(generation: UInt64) async throws -> Int {
        do {
            let fetched = try await pullUsingCurrentToken(generation: generation)
            try requireActive(generation)
            // A key reset noticed on a record-level failure does not abort the pull; the
            // recovery runs once the rest of the pull is durable.
            try await recoverFromEncryptedDataKeyResetIfPending(generation: generation)
            return fetched
        } catch {
            try requireActive(generation)
            if CloudKitEncryptedDataKeyReset.isReset(error) {
                noteEncryptedDataKeyReset(during: "pull")
                try await recoverFromEncryptedDataKeyResetIfPending(generation: generation)
                let fetched = try await pullUsingCurrentToken(generation: generation)
                try requireActive(generation)
                return fetched
            }
            guard Self.isExpiredChangeTokenError(error) else { throw error }
            syncLog.info("CloudKit change token expired; retrying from the beginning.")
            try invalidateAllPushReceipts(generation: generation)
            try afterReceiptInvalidationBeforeTokenPersistence?()
            try requireActive(generation)
            try persistToken(nil, generation: generation)
            changeToken = nil
            let fetched = try await pullUsingCurrentToken(generation: generation)
            try requireActive(generation)
            return fetched
        }
    }

    /// Fetches and applies the zone changes after the saved position, logging where it started
    /// and what it fetched. Returns the number of changes that reached this device's history.
    private func pullUsingCurrentToken(generation: UInt64) async throws -> Int {
        let startingFrom = changeToken == nil ? "nothing" : "saved position"
        syncLog.notice("Sync pull started (starting from: \(startingFrom, privacy: .public))")
        do {
            let fetched = try await fetchAndApplyZoneChanges(generation: generation)
            fetchedChangesTotal += fetched
            syncLog.notice("Sync pull finished (changes: \(fetched, privacy: .public), result: ok)")
            return fetched
        } catch {
            syncLog.notice("Sync pull finished (changes: 0, result: failed)")
            throw error
        }
    }

    private func fetchAndApplyZoneChanges(generation: UInt64) async throws -> Int {
        try requireActive(generation)
        guard let store else { return 0 }
        var accumulation = PullAccumulation()
        var quarantine = QuarantineState(entries: pullQuarantine)
        var token = changeToken
        let startedFromNothing = token == nil
        var moreComing = true
        var fetchedChanges = 0
        var changedHistory = 0
        do {
            // Re-attempt earlier skipped records first, so a recovered one lands in the same
            // durable apply as this pull's page set.
            try await recoverQuarantinedRecords(
                into: store,
                accumulation: &accumulation,
                quarantine: &quarantine,
                generation: generation
            )
            while moreComing {
                let changes = try await database.fetchZoneChanges(zoneID, since: token)
                try requireActive(generation)
                fetchedChanges += changes.changedRecords.count + changes.deletedRecordNames.count
                try quarantinePermanentServerFailures(
                    changes.failedRecords,
                    quarantine: &quarantine
                )
                for record in changes.changedRecords {
                    try requireActive(generation)
                    try await accumulateRemoteRecord(
                        record,
                        into: store,
                        accumulation: &accumulation,
                        quarantine: &quarantine,
                        generation: generation
                    )
                }
                for recordName in changes.deletedRecordNames {
                    // A record deleted server-side has nothing left to recover.
                    quarantine.clear(recordName)
                    forgetErasedVersion(of: recordName)
                    if let id = UUID(uuidString: recordName) {
                        accumulation.remote.append(tombstone(id))
                    }
                }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            try requireActive(generation)
            // Before the snapshot and the apply, so the cap below is the adopted limit rather
            // than this device's old one. Nothing suspends between here and the apply. Adoption is
            // idempotent against the local stamp, so replaying this pull after a later failure
            // re-decides the same way.
            if let remoteSettings = accumulation.remoteSettings {
                if applySettingsFromChangeFeed(remoteSettings) {
                    syncLog.info(
                        "adopted synced history limit \(remoteSettings.historyLimit.rawValue, privacy: .public) before applying \(accumulation.remote.count, privacy: .public) pulled clip(s)"
                    )
                }
                try requireActive(generation)
            }
            let appliedLimit = effectiveHistoryLimit
            let local = store.itemsForSync()
            for bypassed in accumulation.bypassedMissingAssets {
                guard Self.localTombstoneDominates(
                    bypassed.item,
                    in: local
                ) else {
                    throw CloudKitSyncError.missingBlobAsset(bypassed.blob.filename)
                }
            }
            let merged = ClipboardMerge.reconcile(
                Self.droppingHealedBlankItems(
                    from: local,
                    remote: accumulation.remote,
                    healable: accumulation.healableItemIDs
                ),
                accumulation.remote
            )
            // The same text copied on two devices before they synced is one clip. Only clips new
            // to this device qualify, and never in a pull that started from nothing, so history
            // already on a device and a full re-download are left as they are.
            let reconciled = startedFromNothing ? merged : ClipboardMerge.collapsingCrossDeviceDuplicates(
                merged,
                arrivals: Self.arrivingClipIDs(remote: accumulation.remote, local: local),
                pendingDeleteIDs: (store as? any PendingDeletionReporting)?.pendingDeletionIDs ?? []
            )
            try requireActive(generation)
            changedHistory = Self.changedItemCount(from: local, to: reconciled)
            try await applyPulledStateDurably(reconciled, to: store)
            try requireActive(generation)
            deleteDownloadedBlobsNotReferenced(accumulation.downloadedBlobs, in: store)
            let receiptChanges = Self.pullReceiptChanges(
                remote: accumulation.remote,
                reconciled: reconciled,
                repairItemIDs: accumulation.receiptInvalidationItemIDs,
                omittedFields: accumulation.omittedFieldsByItem
            )
            if !receiptChanges.isEmpty {
                // A push that started before this pull may still commit an older receipt
                // snapshot. Let it finish, then make this the last durable receipt transition
                // before acknowledging the remote change token.
                try await awaitActivePushCompletion(generation: generation)
                try requireActive(generation)
                try applyPullReceiptChanges(receiptChanges, generation: generation)
                try afterReceiptInvalidationBeforeTokenPersistence?()
                try requireActive(generation)
            }
            guard !quarantine.didOverflow else {
                throw CloudKitSyncError.pullQuarantineOverflow
            }
            try await eraseReadableCopies(from: accumulation, generation: generation)
            // Durable before the token: a crash here replays the page instead of losing the
            // record that was skipped.
            if quarantine.didChange {
                try persistPullQuarantine(quarantine.entries, generation: generation)
            }
            if let appliedLimit {
                if startedFromNothing {
                    defaults.set(appliedLimit, forKey: historyCoverageKey)
                } else {
                    lowerHistoryCoverage(to: appliedLimit)
                }
            }
            try persistToken(token, generation: generation)
            changeToken = token
            // A refetch from nothing re-delivers records this device already has.
            return startedFromNothing ? changedHistory : fetchedChanges
        } catch {
            if canMutate(generation) {
                deleteDownloadedBlobsNotReferenced(accumulation.downloadedBlobs, in: store)
            }
            throw error
        }
    }

    /// The live clips in this pull that this device has neither as a clip nor as a deleted one.
    nonisolated static func arrivingClipIDs(remote: [ClipboardItem], local: [ClipboardItem]) -> Set<UUID> {
        let known = Set(local.map(\.id))
        return Set(remote.filter { !$0.isDeleted && !known.contains($0.id) }.map(\.id))
    }

    /// How many canonical items are new to `local` or newer than its copy.
    nonisolated static func changedItemCount(
        from local: [ClipboardItem],
        to reconciled: [ClipboardItem]
    ) -> Int {
        let stamps = Dictionary(local.map { ($0.id, $0.modifiedAt) }, uniquingKeysWith: { first, _ in first })
        return reconciled.filter { stamps[$0.id] != $0.modifiedAt }.count
    }

    /// Everything one pull collects before it becomes a single durable apply.
    struct PullAccumulation {
        var remote: [ClipboardItem] = []
        var downloadedBlobs: Set<SyncBlobReference> = []
        var bypassedMissingAssets: [(item: ClipboardItem, blob: SyncBlobReference)] = []
        var receiptInvalidationItemIDs: Set<UUID> = []
        /// The settings record seen in this pull, if any. Last one wins within a pull — the
        /// record is a singleton, so a later page can only be a newer copy of the same thing.
        var remoteSettings: SyncedSettings?
        /// Items whose record holds readable content from a current encrypted copy, which can
        /// replace a blank local copy of the same clip.
        var healableItemIDs: Set<UUID> = []
        /// Derived fields a record's encrypted copy left out because the record would not fit.
        var omittedFieldsByItem: [UUID: Set<String>] = [:]
        /// Records whose readable copy this device erases once the pull is applied.
        var readableCopyErasures: [ReadableCopyErasure] = []
        /// Origins of writers that put readable content back or never learned the encrypted copy.
        var olderDeviceOrigins: [String] = []
    }

    /// In-flight quarantine list for one pull. Only persisted once the pull's records are durable.
    private struct QuarantineState {
        var entries: [String: CloudKitPullQuarantineEntry]
        var didChange = false
        /// A record failed while the list was full and could not be tracked; the pull must
        /// hold the change token, or the record would be skipped with no recovery path.
        var didOverflow = false

        mutating func clear(_ recordName: String) {
            guard entries.removeValue(forKey: recordName) != nil else { return }
            didChange = true
        }

        mutating func record(_ recordName: String, reason: String) {
            let existingAttemptCount = entries[recordName]?.attemptCount
            guard existingAttemptCount != nil
                    || entries.count < CloudKitPullQuarantineCodec.maximumEntryCount else {
                syncLog.error(
                    "quarantine is full; cannot track skipped record \(recordName, privacy: .public): \(reason, privacy: .public)"
                )
                didOverflow = true
                return
            }
            let attemptCount = (existingAttemptCount ?? 0) + 1
            entries[recordName] = CloudKitPullQuarantineEntry(
                reason: CloudKitPullQuarantineCodec.truncatedReason(reason),
                attemptCount: attemptCount
            )
            didChange = true
            if attemptCount >= CloudKitSyncService.maximumQuarantineAttempts {
                syncLog.error(
                    "record \(recordName, privacy: .public) failed \(attemptCount, privacy: .public) resolution attempts; leaving it quarantined for recovery: \(reason, privacy: .public)"
                )
            } else {
                syncLog.error(
                    "quarantining record \(recordName, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
    }

    /// Folds one remote record into the pending pull. A record that can never resolve is
    /// quarantined and skipped instead of holding the change token — and every other record —
    /// hostage forever.
    private func accumulateRemoteRecord(
        _ record: CKRecord,
        into store: SyncableStore,
        accumulation: inout PullAccumulation,
        quarantine: inout QuarantineState,
        generation: UInt64
    ) async throws {
        try requireActive(generation)
        let recordName = record.recordID.recordName
        // Settings records must never reach `ClipboardCloudMapping` (misread as unmappable) or
        // the quarantine — branch on record type first. Single choke point: both the page loop
        // and the quarantine-recovery re-fetch route through here.
        if record.recordType == SyncedSettingsCloudMapping.recordType {
            if let settings = SyncedSettingsCloudMapping.settings(from: record) {
                accumulation.remoteSettings = settings
            } else {
                // Not an error, and nothing to hold the change token for: a value this build
                // cannot read now will not become readable by replaying the same page. The
                // fetch-first reconcile on the next launch is what picks it up after an upgrade.
                syncLog.info(
                    "settings record \(recordName, privacy: .public) is not readable by this build; leaving it to the next reconcile"
                )
            }
            // A 1.0.5 client quarantined this record as an unmappable clip. Now that the type is
            // understood, drop that entry instead of leaving it to burn recovery attempts.
            quarantine.clear(recordName)
            return
        }
        let resolved: RemoteItemResolution?
        do {
            resolved = try await resolveRemoteItem(
                from: record,
                into: store,
                generation: generation
            )
        } catch let error where Self.isPermanentRecordResolutionFailure(error) {
            quarantine.record(recordName, reason: error.localizedDescription)
            return
        }
        try requireActive(generation)
        guard let resolved else {
            quarantine.record(recordName, reason: Self.unmappableRecordReason)
            return
        }
        switch resolved {
        case .available(let item, let blob, let requiresLocalRepush):
            if let blob { accumulation.downloadedBlobs.insert(blob) }
            if requiresLocalRepush {
                accumulation.receiptInvalidationItemIDs.insert(item.id)
            }
            accumulation.remote.append(item)
            noteEncryptedCopyState(of: record, item: item, accumulation: &accumulation)
        case .missingAssetShadowedByLocalTombstone(let item, let blob):
            accumulation.bypassedMissingAssets.append((item, blob))
            accumulation.receiptInvalidationItemIDs.insert(item.id)
            accumulation.remote.append(item)
        }
        quarantine.clear(recordName)
    }

    /// Re-fetches a bounded batch of quarantined records. Recovery is best effort: a transport
    /// failure here must not stop the healthy change feed, and it does not spend a retry.
    private func recoverQuarantinedRecords(
        into store: SyncableStore,
        accumulation: inout PullAccumulation,
        quarantine: inout QuarantineState,
        generation: UInt64
    ) async throws {
        try requireActive(generation)
        let recoverableRecordNames = quarantine.entries
            .filter { $0.value.attemptCount < Self.maximumQuarantineAttempts }
            .keys
            .sorted()
            .prefix(Self.quarantineRecoveryBatchLimit)
        guard !recoverableRecordNames.isEmpty else { return }

        let fetched: CloudKitFetchedRecords
        do {
            fetched = try await database.fetchRecords(
                for: Array(recoverableRecordNames),
                in: zoneID
            )
        } catch {
            try requireActive(generation)
            syncLog.error(
                "quarantined record re-fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        try requireActive(generation)
        if fetched.encryptedDataKeyWasReset {
            noteEncryptedDataKeyReset(during: "quarantine recovery")
        }

        for recordName in fetched.permanentlyMissingRecordNames.sorted() {
            syncLog.info(
                "dropping quarantined record \(recordName, privacy: .public); CloudKit no longer has it"
            )
            quarantine.clear(recordName)
        }
        for record in fetched.records {
            try requireActive(generation)
            try await accumulateRemoteRecord(
                record,
                into: store,
                accumulation: &accumulation,
                quarantine: &quarantine,
                generation: generation
            )
        }
    }

    /// Per-record server failures split by kind: a record CloudKit permanently no longer has is
    /// quarantined and skipped, anything retryable still aborts the pull so the change token is not
    /// advanced past data the server merely failed to hand over this time.
    private func quarantinePermanentServerFailures(
        _ failures: [CloudKitRecordFailure],
        quarantine: inout QuarantineState
    ) throws {
        var retryableCount = 0
        for failure in failures {
            if CloudKitEncryptedDataKeyReset.isReset(failure.error) {
                // Quarantined like a permanent failure: the record is re-fetched after the
                // re-upload has rewritten it.
                noteEncryptedDataKeyReset(during: "pull")
                quarantine.record(failure.recordName, reason: failure.error.localizedDescription)
                continue
            }
            guard Self.isPermanentServerRecordFailure(failure.error) else {
                retryableCount += 1
                continue
            }
            quarantine.record(failure.recordName, reason: failure.error.localizedDescription)
        }
        guard retryableCount == 0 else {
            throw CloudKitSyncError.partialRecordFailures(retryableCount)
        }
    }

    private nonisolated static func isPermanentServerRecordFailure(_ error: any Error) -> Bool {
        cloudKitErrorCode(of: error) == .unknownItem
    }

    /// Permanent when replaying can only fail the same way (blob absent, oversized, or unusable
    /// locally). A local environment failure (e.g. cannot write right now) stays fatal, so the
    /// token is held and the record is retried rather than skipped.
    private nonisolated static func isPermanentRecordResolutionFailure(_ error: any Error) -> Bool {
        if let syncError = error as? CloudKitSyncError, case .missingBlobAsset = syncError {
            return true
        }
        guard let blobError = error as? SyncBlobStorage.Error else { return false }
        switch blobError {
        case .notRegularFile, .unsafeFilename, .oversizedBlob:
            return true
        }
    }

    private nonisolated static let unmappableRecordReason =
        "Record fields cannot be read as a clip."

    private nonisolated static let maximumQuarantineAttempts = 5

    private nonisolated static let quarantineRecoveryBatchLimit = 100

    private enum RemoteItemResolution {
        case available(
            item: ClipboardItem,
            blob: SyncBlobReference?,
            requiresLocalRepush: Bool
        )
        case missingAssetShadowedByLocalTombstone(
            item: ClipboardItem,
            blob: SyncBlobReference
        )
    }

    private func resolveRemoteItem(
        from record: CKRecord,
        into store: SyncableStore,
        generation: UInt64
    ) async throws -> RemoteItemResolution? {
        try requireActive(generation)
        guard let item = ClipboardCloudMapping.item(from: record) else { return nil }
        let refreshesEncryptedCopy = Self.logEncryptedRefresh(for: record, itemID: item.id)
        if !item.isDeleted,
           let blob = item.syncBlobReference,
           (record[ClipboardCloudMapping.Key.blob] as? CKAsset)?.fileURL == nil,
           Self.localTombstoneDominates(item, in: store.itemsForSync()) {
            syncLog.info(
                "skipping missing asset for clip \(item.id.uuidString, privacy: .public) because a local tombstone dominates"
            )
            return .missingAssetShadowedByLocalTombstone(item: item, blob: blob)
        }
        switch try await resolveRemoteBlob(
            from: record,
            for: item,
            into: store,
            generation: generation
        ) {
        case .notRequired:
            return .available(item: item, blob: nil, requiresLocalRepush: refreshesEncryptedCopy)
        case .available(let blob, let requiresLocalRepush):
            return .available(
                item: item,
                blob: blob,
                requiresLocalRepush: requiresLocalRepush || refreshesEncryptedCopy
            )
        }
    }

    /// Reports whether the record's encrypted copy must be rewritten, and says why. A refresh
    /// keeps `modifiedAt`, so it never looks like a new edit to another device.
    private nonisolated static func logEncryptedRefresh(for record: CKRecord, itemID: UUID) -> Bool {
        guard let reason = ClipboardCloudMapping.encryptedRefreshReason(for: record) else { return false }
        let id = itemID.uuidString
        switch reason {
        case .missing:
            syncLog.info("clip \(id, privacy: .public) has no encrypted copy; scheduling a refresh")
        case .unreadable:
            syncLog.info("clip \(id, privacy: .public) has an unreadable encrypted copy; scheduling a refresh")
        case .stale:
            syncLog.info("clip \(id, privacy: .public) has a stale encrypted copy; scheduling a refresh")
        case .tombstoneHoldsContent:
            syncLog.info("tombstone \(id, privacy: .public) still carries encrypted content; scheduling an erase")
        }
        return true
    }

    private nonisolated static func localTombstoneDominates(
        _ remoteItem: ClipboardItem,
        in localItems: [ClipboardItem]
    ) -> Bool {
        let sameIDItems = localItems.filter { $0.id == remoteItem.id }
        guard let localWinner = ClipboardMerge.reconcile(sameIDItems, []).first else {
            return false
        }
        guard let deletedAt = localWinner.deletedAt else { return false }
        return ClipboardMerge.deleteOutranksLiveCopy(deletedAt: deletedAt, liveTimestamp: remoteItem.timestamp)
    }

    private nonisolated static func isExpiredChangeTokenError(_ error: any Error) -> Bool {
        cloudKitErrorCode(of: error) == .changeTokenExpired
    }

    nonisolated static func cloudKitErrorCode(of error: any Error) -> CKError.Code? {
        if let cloudKitError = error as? CKError {
            return cloudKitError.code
        }
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return nil }
        return CKError.Code(rawValue: nsError.code)
    }

    private func pushLocal(generation: UInt64) async throws {
        try requireActive(generation)
        if activePush != nil {
            try await awaitActivePushCompletion(generation: generation)
            try requireActive(generation)
            try await pushLocal(generation: generation)
            return
        }

        let pushID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try self.requireActive(generation)
            try await self.performPushLocal(generation: generation)
        }
        try requireActive(generation)
        activePush = (pushID, task)
        do {
            try await task.value
            try requireActive(generation)
            if activePush?.id == pushID {
                activePush = nil
            }
        } catch {
            if activePush?.id == pushID {
                activePush = nil
            }
            throw error
        }
    }

    /// Applies the pulled state and waits for the disk write without blocking the main actor. The
    /// apply itself runs before the first suspension, so nothing can interleave between taking
    /// the local snapshot and applying it. A push that starts during the wait would read state
    /// that is not durable yet and could record a receipt for it, so pushes wait for this.
    private func applyPulledStateDurably(_ reconciled: [ClipboardItem], to store: SyncableStore) async throws {
        durablePullApplyInFlight = true
        defer {
            durablePullApplyInFlight = false
            let waiters = durablePullApplyWaiters
            durablePullApplyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        try await store.applyReconciledAwaitingDurability(reconciled)
    }

    private func awaitDurablePullApply() async {
        guard durablePullApplyInFlight else { return }
        await withCheckedContinuation { durablePullApplyWaiters.append($0) }
    }

    private func awaitActivePushCompletion(generation: UInt64) async throws {
        try requireActive(generation)
        while let activePush {
            do {
                try await activePush.task.value
                try requireActive(generation)
                if self.activePush?.id == activePush.id {
                    self.activePush = nil
                }
            } catch {
                if self.activePush?.id == activePush.id {
                    self.activePush = nil
                }
                throw error
            }
        }
    }

    private func performPushLocal(generation: UInt64) async throws {
        try requireActive(generation)
        guard let store else { return }
        // Both halves are attempted before either failure is reported: the settings record is
        // independent of the clip batches, so a failing clip batch must not strand a limit the
        // user chose in the same session (nor the reverse).
        var clipError: (any Error)?
        do {
            try await pushLocalClips(store: store, generation: generation)
        } catch {
            clipError = error
        }

        if settingsReconciliationPending, canMutate(generation) {
            do {
                try await reconcileSettings(generation: generation)
            } catch {
                // The clip failure came first and is the more consequential one to surface.
                if clipError == nil { clipError = error }
            }
        }

        if let clipError { throw clipError }
    }

    private func pushLocalClips(
        store: SyncableStore,
        generation: UInt64,
        replanAfterKeyReset: Bool = true
    ) async throws {
        try requireActive(generation)
        await awaitDurablePullApply()
        try requireActive(generation)
        let local = store.itemsForSync()
        let isReceiptMigration = pushReceipts == nil

        let existingReceipts = pushReceipts ?? [:]
        let policy = plainContentPolicy
        var itemsToPush = Self.itemsNeedingPush(local, receipts: pushReceipts)
        if policy == .encryptedOnly {
            // A blank text clip can only be a copy received from a record whose readable content
            // was removed; uploading it would overwrite the good encrypted copy for every device.
            itemsToPush = itemsToPush.filter { !isBlankReceivedTextClip($0) }
        }
        itemsToPush = itemsNotKeptLocalOnly(itemsToPush, among: local)
        let currentItemIDs = Set(local.map(\.id))
        let garbageCollectedReceipts = existingReceipts.filter { currentItemIDs.contains($0.key) }

        try requireActive(generation)
        let prepared = try await prepareClipPushRecords(
            itemsToPush.filter { !$0.isDeleted },
            policy: policy,
            generation: generation
        )
        // A clip CloudKit cannot represent (blob file gone, unusable blob metadata) is skipped
        // instead of blocking every other pending record. It keeps no receipt, so an ordinary
        // later push replays it once the local state is repaired.
        for skippedID in prepared.skippedItemIDs {
            syncLog.error("skipping clip with invalid sync blob metadata: \(skippedID.uuidString, privacy: .public)")
        }
        // Reported on every push that gets this far, including with nothing waiting, which is
        // how the list clears. A stopped or replaced service must not write a stale list.
        if canMutate(generation) {
            reportWaitingClips(prepared.skippedClips)
        }
        let tombstoneRecords = try await prepareTombstonePushRecords(
            itemsToPush.filter(\.isDeleted),
            generation: generation
        )
        if encryptedDataKeyResetPending {
            // The server copies are gone, so what was planned from the old receipts is stale.
            try await recoverFromEncryptedDataKeyResetIfPending(generation: generation)
            guard replanAfterKeyReset else { throw CloudKitSyncError.encryptedDataKeyReset }
            try await pushLocalClips(store: store, generation: generation, replanAfterKeyReset: false)
            return
        }
        let recordsToSave = prepared.records + tombstoneRecords
        guard !recordsToSave.isEmpty else {
            if isReceiptMigration || garbageCollectedReceipts != existingReceipts {
                try persistPushReceipts(garbageCollectedReceipts, generation: generation)
            }
            return
        }

        try requireActive(generation)
        var committedReceipts = existingReceipts
        // Receipts land per accepted batch: a later batch failure must not strand the records
        // CloudKit already took, which would otherwise be re-uploaded by every future push.
        do {
            try await savePreparedRecords(recordsToSave, generation: generation) { batch in
                let canonicalItemIDs = Set(store.itemsForSync().map(\.id))
                committedReceipts = committedReceipts.filter { canonicalItemIDs.contains($0.key) }
                for pushed in batch where canonicalItemIDs.contains(pushed.itemID) {
                    committedReceipts[pushed.itemID] = pushed.modifiedAt
                }
                try persistPushReceipts(committedReceipts, generation: generation)
            }
        } catch CloudKitSyncError.encryptedDataKeyReset where replanAfterKeyReset {
            // Recovery has already emptied the receipts; one more pass uploads every clip.
            try await pushLocalClips(store: store, generation: generation, replanAfterKeyReset: false)
            return
        }
        #if DEBUG
        await logRecordShapes(for: recordsToSave.map(\.record.recordID.recordName))
        #endif
    }

    /// Tombstones save onto the server's fetched record: only assignments on a fetched record
    /// mark `.changedKeys`, erasing the clip's content/asset. A record the server never had gets
    /// a minimal tombstone directly; one merely not handed over yet stays unsent, not downgraded.
    private func prepareTombstonePushRecords(
        _ tombstones: [ClipboardItem],
        generation: UInt64
    ) async throws -> [PreparedPushRecord] {
        guard !tombstones.isEmpty else { return [] }
        var records: [PreparedPushRecord] = []
        records.reserveCapacity(tombstones.count)
        let itemsByRecordName = Dictionary(
            tombstones.map { ($0.id.uuidString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for batch in itemsByRecordName.keys.sorted().chunked(into: 100) {
            let fetched = try await database.fetchRecords(for: batch, in: zoneID)
            try requireActive(generation)
            if fetched.encryptedDataKeyWasReset {
                noteEncryptedDataKeyReset(during: "tombstone preparation")
            }
            let serverRecords = Dictionary(
                fetched.records.map { ($0.recordID.recordName, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for recordName in batch {
                guard let item = itemsByRecordName[recordName] else { continue }
                if let serverRecord = serverRecords[recordName] {
                    ClipboardCloudMapping.applyTombstone(from: item, to: serverRecord)
                    records.append(PreparedPushRecord(
                        itemID: item.id,
                        record: serverRecord,
                        modifiedAt: item.modifiedAt
                    ))
                } else if fetched.permanentlyMissingRecordNames.contains(recordName) {
                    guard let record = ClipboardCloudMapping.record(from: item, in: zoneID) else {
                        continue
                    }
                    records.append(PreparedPushRecord(
                        itemID: item.id,
                        record: record,
                        modifiedAt: item.modifiedAt
                    ))
                }
            }
        }
        return records
    }

    // MARK: - Synced settings

    /// What to do with the settings record after reading the server's copy. Pure and total, so
    /// the last-writer-wins rule is decided in one place and tested without a network.
    enum SettingsResolution: Equatable {
        case idle
        case adopt(SyncedSettings)
        case publish
    }

    /// Last-writer-wins, with two guards that matter more than the happy path:
    /// a remote record this build *cannot read* still defends its slot by stamp alone, and a
    /// limit the local user never chose is never published.
    nonisolated static func settingsResolution(
        local: SyncedSettings,
        remote: RemoteSettingsRecord?
    ) -> SettingsResolution {
        let localStamp = Self.millisecondStamp(local.updatedAt)
        if let remoteSettings = remote?.settings,
           Self.millisecondStamp(remoteSettings.updatedAt) > localStamp {
            return .adopt(remoteSettings)
        }
        if let remote, localStamp <= Self.millisecondStamp(remote.updatedAt) {
            // Older or tied — including against a value this build cannot interpret. The
            // incumbent remote stands and this device stays quiet.
            return .idle
        }
        guard local.wasChosen else { return .idle }
        return .publish
    }

    /// CloudKit does not persist sub-millisecond `Date` precision, so a round-tripped copy of
    /// the local stamp must still compare as a tie — otherwise every reconcile would
    /// republish an identical record.
    private nonisolated static func millisecondStamp(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1_000).rounded())
    }

    /// Reconciles the singleton settings record fetch-first: read the server's copy, decide, and
    /// save *that instance* so the conditional save carries a real change tag. A conflict is then
    /// a genuine mid-flight race rather than the guaranteed cost of every publish.
    private func reconcileSettings(generation: UInt64) async throws {
        try requireActive(generation)
        guard settingsStore?.syncedSettings != nil else { return }

        for _ in 0..<Self.maximumSettingsSaveAttempts {
            try requireActive(generation)
            guard let local = settingsStore?.syncedSettings else { return }
            let serverRecord = try await fetchSettingsRecord(generation: generation)
            try requireActive(generation)

            switch Self.settingsResolution(
                local: local,
                remote: serverRecord.flatMap(SyncedSettingsCloudMapping.remoteRecord(from:))
            ) {
            case .idle:
                settingsReconciliationPending = false
                return
            case .adopt(let remote):
                settingsStore?.applySyncedSettings(remote)
                settingsReconciliationPending = false
                return
            case .publish:
                let record: CKRecord
                if let serverRecord {
                    SyncedSettingsCloudMapping.apply(local, to: serverRecord)
                    record = serverRecord
                } else {
                    record = SyncedSettingsCloudMapping.record(for: local, in: zoneID)
                }
                if try await database.saveRecordIfUnchanged(record) == .saved {
                    try requireActive(generation)
                    settingsReconciliationPending = false
                    return
                }
                // Someone wrote between the fetch and the save. Re-read and re-decide; if they
                // are newer, adopting their value *is* the resolution.
                try requireActive(generation)
            }
        }
        // Losing the race repeatedly is not a sync failure — nothing is lost, and the next
        // trigger re-decides against whatever the server settled on.
        syncLog.info("settings record kept changing mid-save; leaving it for the next sync")
    }

    private func fetchSettingsRecord(generation: UInt64) async throws -> CKRecord? {
        let fetched = try await database.fetchRecords(
            for: [SyncedSettingsCloudMapping.recordName],
            in: zoneID
        )
        try requireActive(generation)
        return fetched.records.first { $0.recordType == SyncedSettingsCloudMapping.recordType }
    }

    /// Live fast path for a settings record in the change feed — lands another device's choice
    /// without waiting for launch. Purely an accelerator; the fetch-first reconcile guarantees
    /// convergence, so an unreadable record here is simply ignored.
    /// Returns whether the record was newer than the local choice and so was adopted.
    @discardableResult
    private func applySettingsFromChangeFeed(_ remote: SyncedSettings) -> Bool {
        guard let settingsStore, let local = settingsStore.syncedSettings else { return false }
        guard Self.millisecondStamp(remote.updatedAt) > Self.millisecondStamp(local.updatedAt) else { return false }
        settingsStore.applySyncedSettings(remote)
        return true
    }

    private nonisolated static let maximumSettingsSaveAttempts = 2

    private func fetchRecordPresence(
        for recordNames: [String],
        generation: UInt64
    ) async throws -> CloudKitRecordPresence {
        var combined = CloudKitRecordPresence()
        for batch in recordNames.chunked(into: 100) {
            let presence = try await database.fetchRecordPresence(for: batch, in: zoneID)
            try requireActive(generation)
            combined.presentRecordNames.formUnion(presence.presentRecordNames)
            combined.missingRecordNames.formUnion(presence.missingRecordNames)
        }
        return combined
    }

    private func savePreparedRecords(
        _ records: [PreparedPushRecord],
        generation: UInt64,
        afterBatch: ([PreparedPushRecord]) throws -> Void = { _ in }
    ) async throws {
        for batch in records.chunked(into: 100) {
            let result: CloudKitRecordSaveResult
            do {
                result = try await database.saveRecords(batch.map(\.record))
            } catch {
                try requireActive(generation)
                if CloudKitEncryptedDataKeyReset.isReset(error) {
                    noteEncryptedDataKeyReset(during: "push")
                    try await recoverFromEncryptedDataKeyResetIfPending(generation: generation)
                    throw CloudKitSyncError.encryptedDataKeyReset
                }
                throw error
            }
            try requireActive(generation)
            guard result.failedRecordNames.isEmpty else {
                if result.encryptedDataKeyWasReset {
                    noteEncryptedDataKeyReset(during: "push")
                    try await recoverFromEncryptedDataKeyResetIfPending(generation: generation)
                    throw CloudKitSyncError.encryptedDataKeyReset
                }
                throw CloudKitSyncError.partialRecordSaves(result.failedRecordNames.count, result.failure)
            }
            try afterBatch(batch)
        }
    }

    // MARK: - Encrypted data key reset

    /// The one place every CloudKit surface reports a reset of the user's encrypted-data key.
    /// Recovery itself runs at a point where it cannot disturb a half-applied pull or push.
    func noteEncryptedDataKeyReset(during phase: String) {
        syncLog.error("iCloud reported a reset encrypted-data key during \(phase, privacy: .public)")
        encryptedDataKeyResetPending = true
    }

    /// The reset removed the zone on the server. Re-create it and forget every acknowledgement and
    /// the change token, so the push that follows uploads each local clip again with a fresh
    /// encrypted copy. Local clips are never deleted because of this error.
    private func recoverFromEncryptedDataKeyResetIfPending(generation: UInt64) async throws {
        try requireActive(generation)
        guard encryptedDataKeyResetPending else { return }
        encryptedDataKeyResetPending = false
        syncLog.info("recovering from a reset encrypted-data key: re-creating the zone and re-uploading local clips")
        try invalidateAllPushReceipts(generation: generation)
        try persistToken(nil, generation: generation)
        changeToken = nil
        try await ensureZone()
        try requireActive(generation)
    }

    // MARK: - Encrypted copy backfill

    /// Clips synced before this build have no encrypted copy and keep a matching push receipt, so
    /// nothing would ever re-upload them. Dropping the receipts once makes the regular, batched and
    /// resumable push upload every clip again. Invalidating before setting the marker means a crash
    /// between the two repeats the invalidation rather than skipping the backfill.
    private func scheduleEncryptedCopyBackfillIfNeeded(generation: UInt64) throws {
        try requireActive(generation)
        guard !defaults.bool(forKey: encryptedCopyBackfillKey) else { return }
        syncLog.info("scheduling a one-time upload of encrypted copies for existing clips")
        try invalidateAllPushReceipts(generation: generation)
        defaults.set(true, forKey: encryptedCopyBackfillKey)
        syncLog.info("encrypted copy backfill marker persisted")
    }

    nonisolated static func itemsNeedingPush(
        _ items: [ClipboardItem],
        receipts: [UUID: Date]?
    ) -> [ClipboardItem] {
        guard let receipts else { return items }
        return items.filter { receipts[$0.id] != $0.modifiedAt }
    }

    struct PreparedPushRecord {
        let itemID: UUID
        let record: CKRecord
        let modifiedAt: Date
    }

    struct PreparedPushRecords {
        let records: [PreparedPushRecord]
        let skippedItemIDs: [UUID]
        /// The same clips as `skippedItemIDs`, with why each one cannot be uploaded.
        var skippedClips: [SyncWaitingClip] = []
    }

    nonisolated static func preparePushRecords(
        _ items: [ClipboardItem],
        in zoneID: CKRecordZone.ID,
        policy: ClipboardCloudMapping.PlainContentPolicy = .dualWrite,
        blobURL: (ClipboardItem) -> URL?
    ) -> PreparedPushRecords {
        var records: [PreparedPushRecord] = []
        var skippedItemIDs: [UUID] = []
        var skippedClips: [SyncWaitingClip] = []
        records.reserveCapacity(items.count)

        for item in items {
            let itemBlobURL = item.isDeleted ? nil : blobURL(item)
            if !item.isDeleted, item.syncBlobReference != nil, itemBlobURL == nil {
                skippedItemIDs.append(item.id)
                skippedClips.append(SyncWaitingClip(id: item.id, reason: .contentFileMissing))
                continue
            }
            guard let record = ClipboardCloudMapping.record(
                from: item,
                in: zoneID,
                blobURL: itemBlobURL,
                policy: policy
            ) else {
                skippedItemIDs.append(item.id)
                skippedClips.append(SyncWaitingClip(id: item.id, reason: .contentInvalid))
                continue
            }
            records.append(PreparedPushRecord(itemID: item.id, record: record, modifiedAt: item.modifiedAt))
        }

        return PreparedPushRecords(records: records, skippedItemIDs: skippedItemIDs, skippedClips: skippedClips)
    }

    func existingBlobURL(for item: ClipboardItem) -> URL? {
        guard let reference = item.syncBlobReference,
              let url = store?.blobURL(for: reference),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private enum RemoteBlobResolution {
        case notRequired
        case available(SyncBlobReference, requiresLocalRepush: Bool)
    }

    private func resolveRemoteBlob(
        from record: CKRecord,
        for item: ClipboardItem,
        into store: SyncableStore,
        generation: UInt64
    ) async throws -> RemoteBlobResolution {
        try requireActive(generation)
        guard !item.isDeleted, let blob = item.syncBlobReference else { return .notRequired }
        let assetURL = (record[ClipboardCloudMapping.Key.blob] as? CKAsset)?.fileURL
        // A blob is immutable per filename (an edit mints a new one), so an on-disk file needs no
        // fetch. This skips re-reading the full (up to 32 MB) CKAsset on every metadata-only edit
        // (pin/tag), which re-surfaces the record in the change feed with its asset attached.
        if let localURL = store.blobURL(for: blob), FileManager.default.fileExists(atPath: localURL.path) {
            let requiresLocalRepush = assetURL == nil
            if requiresLocalRepush {
                syncLog.error(
                    "synced clip \(item.id.uuidString, privacy: .public) is missing its asset; scheduling repair"
                )
            }
            return .available(blob, requiresLocalRepush: requiresLocalRepush)
        }
        guard let assetURL else {
            syncLog.error(
                "cannot apply synced clip \(item.id.uuidString, privacy: .public) because its blob asset is missing"
            )
            throw CloudKitSyncError.missingBlobAsset(blob.filename)
        }
        let data = try await SyncBlobStorage.read(from: assetURL, maxBytes: blob.maximumBytes)
        try requireActive(generation)
        try await writeRemoteBlobStaged(
            data,
            destination: blob,
            into: store,
            generation: generation
        )
        return .available(blob, requiresLocalRepush: false)
    }

    /// Writes a downloaded asset under a throwaway valid blob name, then promotes it only while
    /// this service generation is still active. The store's existing public API stays compatible,
    /// and cancellation-ignoring file I/O can leave at most a staging file that this scope removes.
    private func writeRemoteBlobStaged(
        _ data: Data,
        destination: SyncBlobReference,
        into store: SyncableStore,
        generation: UInt64
    ) async throws {
        guard let staging = SyncBlobReference(
            filename: "\(UUID().uuidString).\(destination.kind.allowedExtension)",
            kind: destination.kind
        ) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }

        defer { store.deleteBlob(staging) }
        try await store.writeBlob(data, reference: staging)
        try requireActive(generation)

        guard let stagingURL = store.blobURL(for: staging),
              let destinationURL = store.blobURL(for: destination) else {
            throw SyncBlobStorage.Error.unsafeFilename
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
    }

    private func deleteDownloadedBlobsNotReferenced(
        _ downloadedBlobs: Set<SyncBlobReference>,
        in store: SyncableStore
    ) {
        guard !downloadedBlobs.isEmpty else { return }
        let keptBlobs = Set(store.itemsForSync().compactMap(\.syncBlobReference))
        for blob in downloadedBlobs.subtracting(keptBlobs) {
            store.deleteBlob(blob)
        }
    }

    private func tombstone(_ id: UUID) -> ClipboardItem {
        let now = Date()
        return ClipboardItem(id: id, type: .text, timestamp: now, modifiedAt: now, deletedAt: now)
    }

    private func persistPushReceipts(
        _ receipts: [UUID: Date],
        generation: UInt64
    ) throws {
        try requireActive(generation)
        try beforeReceiptPersistence?()
        try requireActive(generation)
        guard let data = try? CloudKitPushReceiptCodec.encode(receipts) else {
            throw CloudKitSyncError.pushReceiptEncodingFailed
        }
        try requireActive(generation)
        defaults.set(data, forKey: pushReceiptsKey)
        pushReceipts = receipts
        // Receipt state is authoritative in this build. Removing the legacy checkpoint only after
        // the replacement is durable makes every migration failure retryable by a full replay.
        defaults.removeObject(forKey: pushWatermarkKey)
    }

    /// How push receipts move after one pull's merge.
    struct PullReceiptChanges: Equatable {
        var seeded: [UUID: Date] = [:]
        var invalidated: Set<UUID> = []
        var isEmpty: Bool { seeded.isEmpty && invalidated.isEmpty }
    }

    /// Seeds a receipt only when the reconciled winner exactly matches the server's copy, so the
    /// next push won't echo it back. Any other winner (newer local, or a merged same-stamp record)
    /// loses its receipt and re-publishes; repair items always re-push and are never seeded.
    nonisolated static func pullReceiptChanges(
        remote: [ClipboardItem],
        reconciled: [ClipboardItem],
        repairItemIDs: Set<UUID>,
        omittedFields: [UUID: Set<String>] = [:]
    ) -> PullReceiptChanges {
        var changes = PullReceiptChanges(invalidated: repairItemIDs)
        guard !remote.isEmpty else { return changes }
        let winners = Dictionary(
            reconciled.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var newestRemote: [UUID: ClipboardItem] = [:]
        for item in remote where (newestRemote[item.id]?.modifiedAt ?? .distantPast) < item.modifiedAt {
            newestRemote[item.id] = item
        }
        for (id, remoteItem) in newestRemote {
            guard let winner = winners[id] else { continue }
            if ClipboardCloudMapping.syncedFieldsMatch(winner, remoteItem, omitting: omittedFields[id] ?? []),
               !repairItemIDs.contains(id) {
                changes.seeded[id] = remoteItem.modifiedAt
            } else {
                changes.invalidated.insert(id)
            }
        }
        return changes
    }

    private func applyPullReceiptChanges(
        _ changes: PullReceiptChanges,
        generation: UInt64
    ) throws {
        try requireActive(generation)
        if pushReceipts == nil, changes.seeded.isEmpty {
            // A missing envelope already means every canonical item must be replayed.
            return
        }
        let previousReceipts = pushReceipts
        var receipts = previousReceipts ?? [:]
        for (id, stamp) in changes.seeded {
            receipts[id] = stamp
        }
        for id in changes.invalidated {
            receipts.removeValue(forKey: id)
        }
        if let previousReceipts, previousReceipts == receipts { return }
        try persistPushReceipts(receipts, generation: generation)
    }

    private func invalidateAllPushReceipts(generation: UInt64) throws {
        try requireActive(generation)
        defaults.removeObject(forKey: pushReceiptsKey)
        pushReceipts = nil
        // Settings need no equivalent invalidation: every reconcile reads the server's copy
        // first, so there is no cached acknowledgement that could go stale.
        settingsReconciliationPending = true
    }

    private static func loadPushReceipts(
        from defaults: UserDefaults,
        key: String
    ) -> [UUID: Date]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? CloudKitPushReceiptCodec.decode(data)
    }

    private func persistPullQuarantine(
        _ entries: [String: CloudKitPullQuarantineEntry],
        generation: UInt64
    ) throws {
        try requireActive(generation)
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: pullQuarantineKey)
            pullQuarantine = [:]
            return
        }
        guard let data = try? CloudKitPullQuarantineCodec.encode(entries) else {
            throw CloudKitSyncError.pullQuarantineEncodingFailed
        }
        try requireActive(generation)
        defaults.set(data, forKey: pullQuarantineKey)
        pullQuarantine = entries
    }

    /// A quarantine list that cannot be read is treated as empty: the affected records simply
    /// re-quarantine themselves on the next pull.
    private static func loadPullQuarantine(
        from defaults: UserDefaults,
        key: String
    ) -> [String: CloudKitPullQuarantineEntry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? CloudKitPullQuarantineCodec.decode(data)) ?? [:]
    }

    /// The app version: an upgrade grants quarantined records fresh resolution attempts,
    /// since a record this build cannot read may be readable by the next.
    nonisolated static var defaultResolutionEpoch: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Zeroes attempt counts when the epoch changed, keeping entries and reasons. The marker
    /// only advances once the reset counts are durable, so a failed write retries next launch.
    private static func reQuarantineForEpoch(
        _ entries: [String: CloudKitPullQuarantineEntry],
        epoch: String,
        defaults: UserDefaults,
        quarantineKey: String,
        epochKey: String
    ) -> [String: CloudKitPullQuarantineEntry] {
        guard defaults.string(forKey: epochKey) != epoch else { return entries }
        let reset = entries.mapValues {
            CloudKitPullQuarantineEntry(reason: $0.reason, attemptCount: 0)
        }
        if reset.isEmpty {
            defaults.removeObject(forKey: quarantineKey)
        } else {
            guard let data = try? CloudKitPullQuarantineCodec.encode(reset) else { return entries }
            defaults.set(data, forKey: quarantineKey)
        }
        defaults.set(epoch, forKey: epochKey)
        return reset
    }

    func persistToken(
        _ token: CKServerChangeToken?,
        generation: UInt64
    ) throws {
        try requireActive(generation)
        // A nil token removes the key on purpose: the next pull starts from nothing.
        guard let token else {
            defaults.removeObject(forKey: tokenKey)
            return
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            throw CloudKitSyncError.changeTokenEncodingFailed
        }
        defaults.set(data, forKey: tokenKey)
    }

    var activeGeneration: UInt64? {
        isStopped ? nil : lifecycleGeneration
    }

    func requireActive(_ generation: UInt64) throws {
        guard canMutate(generation) else { throw CancellationError() }
    }

    func canMutate(_ generation: UInt64) -> Bool {
        !isStopped && lifecycleGeneration == generation && !Task.isCancelled
    }

    private func shouldReport(_ error: any Error, generation: UInt64) -> Bool {
        canMutate(generation) && !(error is CancellationError)
    }

    private static let stoppedMessage = "CloudKit sync stopped."

    private static func loadToken(from defaults: UserDefaults, key: String) -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

extension ClipboardItem {
    var syncBlobReference: SyncBlobReference? {
        if let filename = imageFilename { return SyncBlobReference(filename: filename, kind: .image) }
        if let filename = textFilename { return SyncBlobReference(filename: filename, kind: .text) }
        return nil
    }
}
