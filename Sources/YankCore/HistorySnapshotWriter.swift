import Foundation

private enum HistorySnapshotWriterError: LocalizedError {
    case incompleteWrite

    var errorDescription: String? {
        switch self {
        case .incompleteWrite:
            "The history write did not complete."
        }
    }
}

private final class HistorySnapshotWriteCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completedID: UInt64 = 0
    private var completedResult: Result<Void, any Error> = .success(())

    func record(id: UInt64, result: Result<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard id >= completedID else { return }
        completedID = id
        completedResult = result
    }

    func result(for id: UInt64) -> Result<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return completedID == id ? completedResult : nil
    }
}

/// An exact completion handle for one scheduled snapshot. If that snapshot is still
/// debounced when a newer one supersedes it, both receipts resolve from the coalesced
/// write; once dispatched, a receipt remains tied to that specific write result.
final class HistorySnapshotWriteReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuations: [CheckedContinuation<Result<Void, any Error>, Never>] = []

    func value() async -> Result<Void, any Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    fileprivate func resolve(_ result: Result<Void, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuations = self.continuations
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}

/// Owns the off-main persistence of the clip history + tombstones, coalescing a burst of
/// saves into a single trailing write. Shared by the macOS and iOS stores so the
/// snapshot → encode → write pipeline lives in exactly one place (no per-store copy).
///
/// Snapshotting happens on the main actor when `scheduleSave` is called; the encode + write
/// run on a private utility queue. With a non-zero `debounce`, rapid mutations (auto-capture,
/// pin/tag bursts) collapse to a single encode + write of the latest snapshot instead of one
/// O(history) rewrite per change. `flush()` forces any pending write synchronously and waits
/// for the queue to drain — call it on app termination or scene-background so the latest
/// state is durable before the process suspends.
@MainActor
final class HistorySnapshotWriter {
    private struct PendingWrite: Sendable {
        let id: UInt64
        let operation: @Sendable () -> Result<Void, any Error>
        let receipts: [HistorySnapshotWriteReceipt]
    }

    private let historyURL: URL
    private let tombstonesURL: URL
    private let writeOptions: Data.WritingOptions
    private let filePermissions: Int?
    private let fileProtection: FileProtectionType?
    private let debounce: Duration
    private let queue: DispatchQueue
    private let onError: (@Sendable (Error) -> Void)?
    private let failureInjector: (@Sendable (HistorySnapshotTransactionPhase) throws -> Void)?

    /// The most recent snapshot's write, kept until it is dispatched to `queue`.
    private var pendingWrite: PendingWrite?
    private var debounceTask: Task<Void, Never>?
    private var scheduledWriteID: UInt64 = 0
    private let completion = HistorySnapshotWriteCompletion()

    init(
        historyURL: URL,
        tombstonesURL: URL,
        writeOptions: Data.WritingOptions = .atomic,
        filePermissions: Int? = nil,
        fileProtection: FileProtectionType? = nil,
        debounce: Duration = .zero,
        queueLabel: String,
        onError: (@Sendable (Error) -> Void)? = nil,
        failureInjector: (@Sendable (HistorySnapshotTransactionPhase) throws -> Void)? = nil
    ) {
        self.historyURL = historyURL
        self.tombstonesURL = tombstonesURL
        self.writeOptions = writeOptions
        self.filePermissions = filePermissions
        self.fileProtection = fileProtection
        self.debounce = debounce
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.onError = onError
        self.failureInjector = failureInjector
    }

    /// Snapshot the current state and schedule a coalesced write. Calls within the debounce
    /// window collapse to one write of the latest snapshot.
    @discardableResult
    func scheduleSave(
        items: [ClipboardItem],
        tombstones: [UUID: Date],
        keyboardProjectionURL: URL? = nil,
        afterSuccessfulWrite: (@Sendable () -> Void)? = nil,
        onKeyboardProjectionError: (@Sendable (Error) -> Void)? = nil
    ) -> HistorySnapshotWriteReceipt {
        scheduledWriteID += 1
        let writeID = scheduledWriteID
        let receipt = HistorySnapshotWriteReceipt()
        let coalescedReceipts = (pendingWrite?.receipts ?? []) + [receipt]
        pendingWrite = PendingWrite(
            id: writeID,
            operation: makeWriteOperation(
                items: items,
                tombstones: tombstones,
                keyboardProjectionURL: keyboardProjectionURL,
                afterSuccessfulWrite: afterSuccessfulWrite,
                onKeyboardProjectionError: onKeyboardProjectionError
            ),
            receipts: coalescedReceipts
        )

        debounceTask?.cancel()
        guard debounce > .zero else {
            dispatchPending()
            return receipt
        }
        let debounce = self.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.dispatchPending()
        }
        return receipt
    }

    /// Serialize launch-time projection publication with snapshot writes so an older
    /// asynchronously encoded projection can never replace one from a newer snapshot.
    func scheduleKeyboardProjection(
        items: [ClipboardItem],
        to url: URL,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        queue.async {
            do {
                try KeyboardHistoryProjection(items: items).write(to: url)
            } catch {
                onError?(error)
            }
        }
    }

    private func makeWriteOperation(
        items: [ClipboardItem],
        tombstones: [UUID: Date],
        keyboardProjectionURL: URL?,
        afterSuccessfulWrite: (@Sendable () -> Void)?,
        onKeyboardProjectionError: (@Sendable (Error) -> Void)?
    ) -> @Sendable () -> Result<Void, any Error> {
        let historyURL = self.historyURL
        let tombstonesURL = self.tombstonesURL
        let writeOptions = self.writeOptions
        let filePermissions = self.filePermissions
        let fileProtection = self.fileProtection
        let onError = self.onError
        let failureInjector = self.failureInjector
        let transactionURL = HistorySnapshotTransaction.transactionURL(for: historyURL)
        return {
            do {
                // Never replace an interrupted checkpoint. Finish it first or leave it
                // untouched for the loader to recover on the next launch.
                try HistorySnapshotTransaction.replayIfPresent(
                    historyURL: historyURL,
                    tombstonesURL: tombstonesURL
                )

                let envelopeData = try HistorySnapshotTransaction.makeEnvelopeData(
                    items: items,
                    tombstones: tombstones,
                    writeOptions: writeOptions,
                    filePermissions: filePermissions,
                    fileProtection: fileProtection
                )
                try HistorySnapshotTransaction.stage(
                    envelopeData,
                    at: transactionURL,
                    writeOptions: writeOptions,
                    filePermissions: filePermissions,
                    fileProtection: fileProtection
                )
                try failureInjector?(.transactionStaged)

                try HistorySnapshotTransaction.replayIfPresent(
                    historyURL: historyURL,
                    tombstonesURL: tombstonesURL,
                    afterCanonicalWrite: failureInjector
                )
            } catch {
                onError?(error)
                return .failure(error)
            }

            if let keyboardProjectionURL {
                do {
                    try KeyboardHistoryProjection(items: items).write(to: keyboardProjectionURL)
                } catch {
                    onKeyboardProjectionError?(error)
                }
            }
            afterSuccessfulWrite?()
            return .success(())
        }
    }

    /// Run any pending write now and block until the queue has drained it (plus any
    /// already-in-flight write). The result belongs to the latest scheduled snapshot, so
    /// callers that checkpoint external state can advance only after confirmed durability.
    @discardableResult
    func flush() -> Result<Void, any Error> {
        debounceTask?.cancel()
        debounceTask = nil
        dispatchPending()
        let writeID = scheduledWriteID
        guard writeID > 0 else { return .success(()) }
        queue.sync {}   // barrier: wait for the serial queue to finish the write
        return completion.result(for: writeID) ?? .failure(HistorySnapshotWriterError.incompleteWrite)
    }

    private func dispatchPending() {
        debounceTask = nil
        guard let work = pendingWrite else { return }
        pendingWrite = nil
        let completion = self.completion
        queue.async {
            let result = work.operation()
            completion.record(id: work.id, result: result)
            for receipt in work.receipts {
                receipt.resolve(result)
            }
        }
    }

}
