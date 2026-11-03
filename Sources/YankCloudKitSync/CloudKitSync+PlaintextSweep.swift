import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

// The one-time sweep that moves every existing clip record's readable content into its encrypted
// copy and erases the readable keys. It pages through the zone on its own change token, so the
// pull's token and the local history are never touched, and it resumes where it stopped.
extension CloudKitSyncService {
    /// Starts the sweep when the rollout is open and no device has finished it. Never awaited by
    /// `start()` or a remote change, so it cannot delay a push or the sync status.
    func startPlaintextSweepIfNeeded(generation: UInt64) {
        guard rolloutDeviceID != nil,
              canMutate(generation),
              activeSweep == nil,
              isEncryptedOnly,
              !rolloutState.isSweepDone else { return }
        let sweepID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPlaintextSweep(generation: generation, sweepID: sweepID)
        }
        activeSweep = (sweepID, task)
    }

    private enum SweepOutcome {
        case finished
        /// Stopped on purpose or by the per-invocation bound; progress is saved.
        case paused(continueSoon: Bool)
        case failed
    }

    private func runPlaintextSweep(generation: UInt64, sweepID: UUID) async {
        let outcome = await sweepReadableCopies(generation: generation)
        if activeSweep?.id == sweepID { activeSweep = nil }
        guard canMutate(generation) else { return }
        publishEncryptionStatus()
        switch outcome {
        case .finished:
            // Publishes `sweepCompletedAt` so other devices skip the sweep.
            rolloutReevaluationRequested = true
            try? await reconcileEncryptionRollout(generation: generation)
        case .paused(let continueSoon):
            guard continueSoon else { return }
            try? await Task.sleep(for: PlaintextSweepLimits.continuationDelay)
            startPlaintextSweepIfNeeded(generation: generation)
        case .failed:
            break
        }
    }

    private func sweepReadableCopies(generation: UInt64) async -> SweepOutcome {
        let state = rolloutState
        var token = state.sweepToken
        if token == nil {
            syncLog.info("removing readable copies from iCloud")
        } else {
            syncLog.info("resuming sweep")
        }
        publishEncryptionStatus()
        var convertedThisRun = 0
        var pagesThisRun = 0
        var unresolved: Set<String> = []
        do {
            var moreComing = true
            while moreComing {
                try requireActive(generation)
                let changes = try await database.fetchZoneChanges(
                    zoneID,
                    since: token,
                    desiredKeys: ClipboardCloudMapping.contentFetchKeys,
                    resultsLimit: PlaintextSweepLimits.effectivePageSize
                )
                try requireActive(generation)
                let records = changes.changedRecords.filter { $0.recordType == ClipboardCloudMapping.recordType }
                let converted = try await convertReadableCopies(
                    in: records,
                    unresolved: &unresolved,
                    generation: generation
                )
                convertedThisRun += converted
                state.sweepCount += converted
                token = changes.changeToken
                moreComing = changes.moreComing
                state.sweepToken = token
                pagesThisRun += 1
                #if DEBUG
                if let stopAfter = DebugRolloutOverrides.stopSweepAfterPages,
                   pagesThisRun >= stopAfter, moreComing {
                    let pageWord = pagesThisRun == 1 ? "page" : "pages"
                    syncLog.info("sweep paused after \(pagesThisRun, privacy: .public) \(pageWord, privacy: .public) (debug)")
                    return .paused(continueSoon: false)
                }
                #endif
                if moreComing, convertedThisRun >= PlaintextSweepLimits.recordsPerInvocation {
                    syncLog.info(
                        "sweep paused after \(convertedThisRun, privacy: .public) records; it continues shortly"
                    )
                    return .paused(continueSoon: true)
                }
                await Task.yield()
            }
            try await retryUnresolvedReadableCopies(&unresolved, generation: generation)
        } catch {
            return handleSweepFailure(error, generation: generation)
        }
        let abandoned = state.sweepAttempts.filter { $0.value >= PlaintextSweepLimits.attemptLimit }
        for name in abandoned.keys.sorted() {
            syncLog.error("sweep gave up on record \(name, privacy: .public) after repeated failures")
        }
        state.sweepCompletedAt = Date()
        syncLog.info("sweep finished: \(state.sweepCount, privacy: .public) records")
        state.clearSweepProgress()
        return .finished
    }

    private func handleSweepFailure(_ error: any Error, generation: UInt64) -> SweepOutcome {
        guard canMutate(generation) else { return .failed }
        if CloudKitEncryptedDataKeyReset.isReset(error) {
            noteEncryptedDataKeyReset(during: "sweep")
            // The zone is gone and is re-created without readable content.
            rolloutState.clearSweepProgress()
            return .failed
        }
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain, nsError.code == CKError.Code.changeTokenExpired.rawValue {
            syncLog.info("sweep position expired; it starts again from the beginning")
            rolloutState.clearSweepProgress()
            return .failed
        }
        // Retried at the next start or remote change; the sweep never turns sync red.
        syncLog.error("sweep stopped, will retry: \(error.localizedDescription, privacy: .public)")
        return .failed
    }

    /// Converts the records of one page that still hold readable content. Returns how many were
    /// saved; records that failed or conflicted are added to `unresolved` and counted as attempts.
    private func convertReadableCopies(
        in records: [CKRecord],
        unresolved: inout Set<String>,
        generation: UInt64
    ) async throws -> Int {
        let state = rolloutState
        var attempts = state.sweepAttempts
        var convertible: [CKRecord] = []
        for record in records where ClipboardCloudMapping.hasPlainContent(record) {
            let name = record.recordID.recordName
            guard attempts[name, default: 0] < PlaintextSweepLimits.attemptLimit else { continue }
            if ClipboardCloudMapping.eraseReadableCopy(of: record) { convertible.append(record) }
        }
        guard !convertible.isEmpty else { return 0 }
        let result = try await database.saveRecords(convertible, savePolicy: .ifServerRecordUnchanged)
        try requireActive(generation)
        if result.encryptedDataKeyWasReset {
            noteEncryptedDataKeyReset(during: "sweep")
        }
        let notSaved = Set(result.failedRecordNames).union(result.conflictedRecordNames)
        for name in notSaved.sorted() {
            attempts[name, default: 0] += 1
            unresolved.insert(name)
        }
        state.sweepAttempts = attempts
        let savedNames = convertible.map(\.recordID.recordName).filter { !notSaved.contains($0) }
        #if DEBUG
        await logRecordShapes(for: savedNames)
        #endif
        return savedNames.count
    }

    /// A conflict means someone wrote the record while the sweep held it, and the sweep's token
    /// may already have passed that write. Each such record is read again by name and converted, up
    /// to the attempt limit; after that it no longer blocks completion.
    private func retryUnresolvedReadableCopies(
        _ unresolved: inout Set<String>,
        generation: UInt64
    ) async throws {
        let state = rolloutState
        while !unresolved.isEmpty {
            let names = unresolved
                .filter { state.sweepAttempts[$0, default: 0] < PlaintextSweepLimits.attemptLimit }
                .sorted()
            unresolved = []
            for batch in names.chunked(into: PlaintextSweepLimits.pageSize) {
                let fetched = try await database.fetchRecords(
                    for: batch,
                    in: zoneID,
                    desiredKeys: ClipboardCloudMapping.contentFetchKeys
                )
                try requireActive(generation)
                if fetched.encryptedDataKeyWasReset {
                    noteEncryptedDataKeyReset(during: "sweep")
                }
                var stillUnresolved: Set<String> = []
                _ = try await convertReadableCopies(
                    in: fetched.records,
                    unresolved: &stillUnresolved,
                    generation: generation
                )
                unresolved.formUnion(stillUnresolved)
            }
        }
    }
}
