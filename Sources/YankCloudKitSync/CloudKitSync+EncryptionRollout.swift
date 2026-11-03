import Foundation
import CloudKit
import os
#if SWIFT_PACKAGE
import YankCore
#endif

/// A pulled record whose readable copy this device erases once the pull is applied.
struct ReadableCopyErasure {
    let record: CKRecord
    /// The record's `modifiedAt` in milliseconds when it was pulled.
    let version: Int64
}

// The move to encrypted-only clip content: a per-device record in its own zone, the rule that
// decides when readable copies stop being written, the write mode itself, and the pull-time rules
// that keep a blank readable field from ever overwriting encrypted content.
extension CloudKitSyncService {
    /// Opts this service into the encrypted-only rollout. `deviceID` names this install's device
    /// record (and matches `deviceOrigin` on the clips it captures); `statusReporter` receives the
    /// progress shown in Settings. Call before `start()`. A service that is never opted in keeps
    /// writing readable copies next to the encrypted ones and never publishes a device record.
    public func enableEncryptionRollout(
        deviceID: String,
        statusReporter: (any SyncEncryptionStatusReporting)?
    ) {
        guard activeGeneration != nil else { return }
        rolloutDeviceID = deviceID
        encryptionStatusReporter = statusReporter
        publishEncryptionStatus()
    }

    // MARK: - Write mode

    var plainContentPolicy: ClipboardCloudMapping.PlainContentPolicy {
        rolloutState.encryptedOnlySince == nil ? .dualWrite : .encryptedOnly
    }

    var isEncryptedOnly: Bool {
        rolloutState.encryptedOnlySince != nil
    }

    /// A live text clip with no text, no recognized text and no asset. Capture never creates one,
    /// so it can only be a copy received from a record whose readable fields were blank.
    nonisolated static func isBlankReceivedText(_ item: ClipboardItem) -> Bool {
        !item.isDeleted
            && item.type == .text
            && item.syncBlobReference == nil
            && (item.textContent ?? "").isEmpty
            && (item.ocrText ?? "").isEmpty
    }

    func isBlankReceivedTextClip(_ item: ClipboardItem) -> Bool {
        guard Self.isBlankReceivedText(item) else { return false }
        if loggedBlankClipIDs.insert(item.id).inserted {
            syncLog.info(
                "not uploading clip \(item.id.uuidString, privacy: .public): its text is blank here and the encrypted copy may hold it"
            )
        }
        return true
    }

    /// Replaces a blank local text clip with the remote clip when the remote record holds readable
    /// content from a current encrypted copy. `ClipboardMerge` keeps the local copy on a tie, which
    /// would keep the blank; this sync-layer rule repairs it without changing the public merge.
    nonisolated static func droppingHealedBlankItems(
        from local: [ClipboardItem],
        remote: [ClipboardItem],
        healable: Set<UUID>
    ) -> [ClipboardItem] {
        guard !healable.isEmpty else { return local }
        var newestRemote: [UUID: ClipboardItem] = [:]
        for item in remote where healable.contains(item.id) {
            if (newestRemote[item.id]?.modifiedAt ?? .distantPast) < item.modifiedAt {
                newestRemote[item.id] = item
            }
        }
        return local.filter { item in
            guard isBlankReceivedText(item),
                  let remoteItem = newestRemote[item.id],
                  !remoteItem.isDeleted,
                  remoteItem.modifiedAt >= item.modifiedAt else { return true }
            syncLog.info("repairing blank clip \(item.id.uuidString, privacy: .public) from the encrypted copy")
            return false
        }
    }

    /// Builds the records for live clips. In encrypted-only mode a clip is saved onto the
    /// server's copy with its old readable keys cleared: a fresh record leaves unset server keys
    /// untouched, so an edit would otherwise leave the previous readable content behind.
    func prepareClipPushRecords(
        _ items: [ClipboardItem],
        policy: ClipboardCloudMapping.PlainContentPolicy,
        generation: UInt64
    ) async throws -> PreparedPushRecords {
        let fresh = Self.preparePushRecords(items, in: zoneID, policy: policy) { item in
            existingBlobURL(for: item)
        }
        guard policy == .encryptedOnly, !fresh.records.isEmpty else { return fresh }
        var records: [PreparedPushRecord] = []
        records.reserveCapacity(fresh.records.count)
        for batch in fresh.records.chunked(into: 100) {
            let fetched = try await database.fetchRecords(
                for: batch.map { $0.record.recordID.recordName },
                in: zoneID,
                desiredKeys: ClipboardCloudMapping.contentFetchKeys
            )
            try requireActive(generation)
            if fetched.encryptedDataKeyWasReset {
                noteEncryptedDataKeyReset(during: "push preparation")
            }
            let serverRecords = Dictionary(
                fetched.records.map { ($0.recordID.recordName, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for prepared in batch {
                let recordName = prepared.record.recordID.recordName
                if let serverRecord = serverRecords[recordName] {
                    ClipboardCloudMapping.merge(prepared.record, onto: serverRecord)
                    records.append(PreparedPushRecord(
                        itemID: prepared.itemID,
                        record: serverRecord,
                        modifiedAt: prepared.modifiedAt
                    ))
                } else if fetched.permanentlyMissingRecordNames.contains(recordName) {
                    records.append(prepared)
                } else {
                    syncLog.info(
                        "server copy of clip \(recordName, privacy: .public) is not available yet; leaving it for the next push"
                    )
                }
            }
        }
        return PreparedPushRecords(
            records: records,
            skippedItemIDs: fresh.skippedItemIDs,
            skippedClips: fresh.skippedClips
        )
    }

    // MARK: - Upgrade: repair blank clips

    /// A device that received blank clips before it was updated holds blank local copies. On the
    /// first launch of an upgraded build, when the rollout is already open, the local change token is
    /// cleared once so the next pull re-reads every record and the heal rule repairs the blanks
    /// from the encrypted copy. Adoption is checked before that pull. Only the local token is
    /// cleared; nothing on the server changes.
    func prepareBlankRepairIfNeeded(generation: UInt64) async throws {
        guard rolloutDeviceID != nil,
              !defaults.bool(forKey: encryptedCopyBackfillKey),
              !rolloutState.blankRepairDone else { return }
        try await reconcileEncryptionRollout(generation: generation)
        guard isEncryptedOnly else { return }
        syncLog.info("repairing blank clips from the encrypted copy")
        try persistToken(nil, generation: generation)
        changeToken = nil
        rolloutState.blankRepairDone = true
    }

    // MARK: - Rollout evaluation

    /// Works out whether readable copies can stop being written, publishes this device's record
    /// and keeps the status current. Single-flight, throttled in memory (the first run of a launch
    /// is never skipped), and it never fails clip sync: a device-zone error is logged and the
    /// rollout state stays as it was.
    func reconcileEncryptionRollout(generation: UInt64) async throws {
        guard rolloutDeviceID != nil else { return }
        try requireActive(generation)
        if let running = activeRolloutEvaluation {
            await running.task.value
            try requireActive(generation)
            return
        }
        let now = Date()
        if !rolloutReevaluationRequested,
           let last = lastRolloutEvaluation,
           now.timeIntervalSince(last) < EncryptionRolloutTiming.interval {
            return
        }
        rolloutReevaluationRequested = false
        lastRolloutEvaluation = now
        let evaluationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.evaluateEncryptionRollout(generation: generation)
        }
        activeRolloutEvaluation = (evaluationID, task)
        await task.value
        if activeRolloutEvaluation?.id == evaluationID { activeRolloutEvaluation = nil }
        try requireActive(generation)
    }

    private struct DeviceRecord {
        let state: CloudKitDeviceRegistry.DeviceState
        let record: CKRecord
    }

    private func evaluateEncryptionRollout(generation: UInt64) async {
        guard let deviceID = rolloutDeviceID else { return }
        do {
            try await database.ensureZone(devicesZoneID)
            let devices = try await fetchDeviceRecords()
            guard canMutate(generation) else { return }
            let evidence = applyRolloutDecision(deviceID: deviceID, devices: devices)
            try await publishOwnDeviceRecord(deviceID: deviceID, devices: devices, olderOrigins: evidence)
        } catch {
            guard canMutate(generation) else { return }
            syncLog.error("could not update device records: \(error.localizedDescription, privacy: .public)")
        }
        guard canMutate(generation) else { return }
        publishEncryptionStatus()
        startPlaintextSweepIfNeeded(generation: generation)
    }

    private func fetchDeviceRecords() async throws -> [String: DeviceRecord] {
        var devices: [String: DeviceRecord] = [:]
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let changes = try await database.fetchZoneChanges(devicesZoneID, since: token)
            for record in changes.changedRecords {
                guard let state = CloudKitDeviceRegistry.state(from: record) else { continue }
                devices[state.deviceID] = DeviceRecord(state: state, record: record)
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return devices
    }

    /// Decides the rollout from the device records and the evidence of older devices, persists
    /// the outcome, and returns the older-device evidence this device publishes.
    private func applyRolloutDecision(
        deviceID: String,
        devices: [String: DeviceRecord]
    ) -> [String: Date] {
        let now = Date()
        let state = rolloutState
        let states = devices.mapValues(\.state)
        let known = Set(states.keys).union([deviceID])
        state.deviceRecordIDs = Set(states.keys)

        let evidence = updatedOlderOriginEvidence(deviceID: deviceID, states: states, known: known, now: now)
        state.olderOrigins = evidence

        let signalWindow = EncryptionRolloutTiming.olderDeviceSignalWindow
        state.olderSignals = state.olderSignals.filter { origin, seen in
            now.timeIntervalSince(seen) < signalWindow && (origin.isEmpty || !known.contains(origin))
        }

        let earliestCreation = states.values.compactMap(\.creationDate).min()
        let soakEnd = earliestCreation.map { $0.addingTimeInterval(EncryptionRolloutTiming.soak) }
        if state.encryptedOnlySince == nil {
            if let adopted = states.values.compactMap(\.content.encryptedOnlySince).min() {
                state.encryptedOnlySince = adopted
                syncLog.info("encrypted-only mode adopted from another device")
            } else if states[deviceID] == nil {
                syncLog.info("keeping plaintext copies: this device's record is not published yet")
            } else if let soakEnd, now < soakEnd {
                syncLog.info("keeping plaintext copies: soak period")
            } else if !evidence.isEmpty {
                syncLog.info("keeping plaintext copies: an older device was seen")
            } else if soakEnd != nil {
                state.encryptedOnlySince = now
                syncLog.info("encrypted-only mode opened")
            }
        }
        if state.encryptedOnlySince == nil {
            state.earliestCompletion = soakEnd
            state.olderActivityLastSeen = evidence.values.max()
        } else if states.values.contains(where: { $0.content.sweepCompletedAt != nil }),
                  state.sweepCompletedAt == nil, !state.sweepAdopted {
            state.sweepAdopted = true
            state.clearSweepProgress()
            syncLog.info("sweep already reported complete")
        }
        return evidence
    }

    /// Older-device evidence: activity of origins that have no device record, kept past history
    /// trimming and unioned with what the other devices publish. An origin another device saw but
    /// this one has no time for is credited now, which can only make the rollout wait longer.
    private func updatedOlderOriginEvidence(
        deviceID: String,
        states: [String: CloudKitDeviceRegistry.DeviceState],
        known: Set<String>,
        now: Date
    ) -> [String: Date] {
        var evidence = rolloutState.olderOrigins
        for item in store?.itemsForSync() ?? [] where !item.deviceOrigin.isEmpty && !known.contains(item.deviceOrigin) {
            evidence[item.deviceOrigin] = max(evidence[item.deviceOrigin] ?? .distantPast, item.modifiedAt)
        }
        for other in states.values where other.deviceID != deviceID {
            for origin in other.content.olderOrigins where !known.contains(origin) && evidence[origin] == nil {
                evidence[origin] = now
            }
        }
        let window = EncryptionRolloutTiming.activityWindow
        let recent = evidence.filter { !known.contains($0.key) && now.timeIntervalSince($0.value) < window }
        guard recent.count > EncryptionRolloutTiming.persistedOriginLimit else { return recent }
        let newest = recent.sorted { $0.value > $1.value }.prefix(EncryptionRolloutTiming.persistedOriginLimit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    /// Writes this device's record when it does not exist or its content changed. A change wakes
    /// every device through the database subscription, so nothing is rewritten on a timer.
    private func publishOwnDeviceRecord(
        deviceID: String,
        devices: [String: DeviceRecord],
        olderOrigins: [String: Date]
    ) async throws {
        let state = rolloutState
        let published = olderOrigins
            .sorted { $0.value > $1.value }
            .prefix(CloudKitDeviceRegistry.maximumOlderOrigins)
            .map(\.key)
        let desired = CloudKitDeviceRegistry.Content(
            encryptedOnlySince: state.encryptedOnlySince,
            sweepCompletedAt: state.sweepCompletedAt,
            olderOrigins: Array(published)
        )
        let existing = devices[deviceID]
        if let existing, existing.state.content.matches(desired) { return }
        let record = CloudKitDeviceRegistry.record(
            for: deviceID,
            content: desired,
            in: devicesZoneID,
            existing: existing?.record
        )
        let result = try await database.saveRecords([record])
        guard result.failedRecordNames.isEmpty else {
            throw CloudKitSyncError.partialRecordSaves(result.failedRecordNames.count, result.failure)
        }
        if existing == nil {
            syncLog.info("published encryption device record \(deviceID, privacy: .public)")
        }
    }

    // MARK: - Status

    func currentEncryptionStatus(now: Date = Date()) -> SyncEncryptionStatus {
        let state = rolloutState
        guard state.encryptedOnlySince != nil else {
            return .finishing(
                earliestCompletion: state.earliestCompletion,
                olderDeviceLastSeen: state.olderActivityLastSeen
            )
        }
        let window = EncryptionRolloutTiming.olderDeviceSignalWindow
        let recentSignals = state.olderSignals.values.filter { now.timeIntervalSince($0) < window }
        if let lastSeen = recentSignals.max() { return .olderDeviceSeen(lastSeen: lastSeen) }
        return state.isSweepDone ? .complete : .removingReadableCopies
    }

    func publishEncryptionStatus() {
        guard rolloutDeviceID != nil, let encryptionStatusReporter else { return }
        encryptionStatusReporter.markEncryptionStatus(currentEncryptionStatus())
    }

    // MARK: - Pull rules

    /// Looks at a pulled live record's encrypted copy: remembers what can repair a blank local
    /// clip, which derived fields were left out, and what the pull-time erase has to do.
    func noteEncryptedCopyState(
        of record: CKRecord,
        item: ClipboardItem,
        accumulation: inout PullAccumulation
    ) {
        let recordName = record.recordID.recordName
        guard !item.isDeleted else {
            forgetErasedVersion(of: recordName)
            return
        }
        let state = ClipboardCloudMapping.encryptedCopyState(of: record)
        if case .current(let payload) = state {
            if !(item.textContent ?? "").isEmpty || !(item.ocrText ?? "").isEmpty {
                accumulation.healableItemIDs.insert(item.id)
            }
            if let omitted = payload.omittedFields, !omitted.isEmpty {
                accumulation.omittedFieldsByItem[item.id] = Set(omitted)
            }
            if payload.plainRemoved == true, rolloutDeviceID != nil, !isEncryptedOnly {
                // Another device opened the rollout: adopt it now instead of at the next hour.
                rolloutReevaluationRequested = true
            }
        }
        guard isEncryptedOnly, ClipboardCloudMapping.hasPlainContent(record) else { return }
        let origin = record[ClipboardCloudMapping.Key.deviceOrigin] as? String ?? ""
        switch state {
        case .current:
            guard let modifiedAt = record[ClipboardCloudMapping.Key.modifiedAt] as? Date else { return }
            let version = ClipboardCloudMapping.millisecondStamp(modifiedAt)
            if rolloutState.erasedVersions[recordName] == version {
                // This device already erased this version once. An older device that is still
                // online writes it back; fighting it would never end.
                syncLog.info(
                    "readable copy came back after erase; leaving it: \(recordName, privacy: .public)"
                )
                accumulation.olderDeviceOrigins.append(origin)
            } else {
                accumulation.readableCopyErasures.append(
                    ReadableCopyErasure(record: record, version: version)
                )
            }
        case .absent, .unreadable, .stale:
            // A build that writes readable fields without learning the encrypted copy wrote this.
            // Before the sweep ends, records like this are expected and the sweep converts them.
            if rolloutState.isSweepDone { accumulation.olderDeviceOrigins.append(origin) }
        case .newerFormat:
            break
        }
    }

    /// Erases the readable copies found by a pull, saving each onto the pulled record only while
    /// the server copy is unchanged, before the change token advances so a crash replays the page.
    func eraseReadableCopies(from accumulation: PullAccumulation, generation: UInt64) async throws {
        if !accumulation.olderDeviceOrigins.isEmpty {
            recordOlderDeviceSignals(accumulation.olderDeviceOrigins)
        }
        var erasures: [ReadableCopyErasure] = []
        for erasure in accumulation.readableCopyErasures
        where ClipboardCloudMapping.eraseReadableCopy(of: erasure.record) {
            syncLog.info("erasing readable copy of clip \(erasure.record.recordID.recordName, privacy: .public)")
            erasures.append(erasure)
        }
        for batch in erasures.chunked(into: 100) {
            let result: CloudKitRecordSaveResult
            do {
                result = try await database.saveRecords(
                    batch.map(\.record),
                    savePolicy: .ifServerRecordUnchanged
                )
            } catch {
                try requireActive(generation)
                throw error
            }
            try requireActive(generation)
            if result.encryptedDataKeyWasReset {
                noteEncryptedDataKeyReset(during: "erase")
            }
            let notSaved = Set(result.failedRecordNames).union(result.conflictedRecordNames)
            var erased = rolloutState.erasedVersions
            for erasure in batch {
                let recordName = erasure.record.recordID.recordName
                if notSaved.contains(recordName) {
                    syncLog.info(
                        "readable copy of clip \(recordName, privacy: .public) changed or could not be erased; the next pull looks again"
                    )
                } else {
                    erased[recordName] = erasure.version
                }
            }
            rolloutState.erasedVersions = Self.prunedErasedVersions(erased)
            #if DEBUG
            await logRecordShapes(for: batch.map(\.record.recordID.recordName))
            #endif
        }
        publishEncryptionStatus()
    }

    func forgetErasedVersion(of recordName: String) {
        var erased = rolloutState.erasedVersions
        guard erased.removeValue(forKey: recordName) != nil else { return }
        rolloutState.erasedVersions = erased
    }

    private static func prunedErasedVersions(_ erased: [String: Int64]) -> [String: Int64] {
        guard erased.count > EncryptionRolloutTiming.erasedVersionLimit else { return erased }
        let newest = erased.sorted { $0.value > $1.value }.prefix(EncryptionRolloutTiming.erasedVersionLimit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    /// Notes that an older build wrote readable content after the switch. An origin that already
    /// has a device record cannot be named as the older device (an older build may only have edited
    /// its clip), so it is kept unattributed and ages out.
    private func recordOlderDeviceSignals(_ origins: [String]) {
        let known = rolloutState.deviceRecordIDs.union(rolloutDeviceID.map { [$0] } ?? [])
        var signals = rolloutState.olderSignals
        let now = Date()
        for origin in origins {
            signals[known.contains(origin) ? "" : origin] = now
        }
        rolloutState.olderSignals = signals
        rolloutReevaluationRequested = true
        publishEncryptionStatus()
    }
}
