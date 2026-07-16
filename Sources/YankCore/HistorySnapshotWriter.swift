import Foundation

private enum HistorySnapshotWriterError: LocalizedError {
    case tombstoneEncodingFailed
    case incompleteWrite

    var errorDescription: String? {
        switch self {
        case .tombstoneEncodingFailed:
            "The deletion log could not be encoded."
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
    }

    private let historyURL: URL
    private let tombstonesURL: URL
    private let writeOptions: Data.WritingOptions
    private let filePermissions: Int?
    private let fileProtection: FileProtectionType?
    private let debounce: Duration
    private let queue: DispatchQueue
    private let onError: (@Sendable (Error) -> Void)?

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
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.historyURL = historyURL
        self.tombstonesURL = tombstonesURL
        self.writeOptions = writeOptions
        self.filePermissions = filePermissions
        self.fileProtection = fileProtection
        self.debounce = debounce
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.onError = onError
    }

    /// Snapshot the current state and schedule a coalesced write. Calls within the debounce
    /// window collapse to one write of the latest snapshot.
    func scheduleSave(
        items: [ClipboardItem],
        tombstones: [UUID: Date],
        afterSuccessfulWrite: (@Sendable () -> Void)? = nil
    ) {
        scheduledWriteID += 1
        let writeID = scheduledWriteID
        pendingWrite = PendingWrite(
            id: writeID,
            operation: makeWriteOperation(
                items: items,
                tombstones: tombstones,
                afterSuccessfulWrite: afterSuccessfulWrite
            )
        )

        debounceTask?.cancel()
        guard debounce > .zero else {
            dispatchPending()
            return
        }
        let debounce = self.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.dispatchPending()
        }
    }

    private func makeWriteOperation(
        items: [ClipboardItem],
        tombstones: [UUID: Date],
        afterSuccessfulWrite: (@Sendable () -> Void)?
    ) -> @Sendable () -> Result<Void, any Error> {
        let historyURL = self.historyURL
        let tombstonesURL = self.tombstonesURL
        let writeOptions = self.writeOptions
        let filePermissions = self.filePermissions
        let fileProtection = self.fileProtection
        let onError = self.onError
        return {
            var firstError: (any Error)?
            do {
                try JSONEncoder().encode(items).write(to: historyURL, options: writeOptions)
                try PrivateFileAttributes.apply(
                    to: historyURL,
                    permissions: filePermissions,
                    protection: fileProtection
                )
            } catch {
                firstError = error
                onError?(error)
            }
            if let data = TombstoneCodec.encode(tombstones) {
                do {
                    try data.write(to: tombstonesURL, options: writeOptions)
                    try PrivateFileAttributes.apply(
                        to: tombstonesURL,
                        permissions: filePermissions,
                        protection: fileProtection
                    )
                } catch {
                    if firstError == nil { firstError = error }
                    onError?(error)
                }
            } else {
                let error = HistorySnapshotWriterError.tombstoneEncodingFailed
                if firstError == nil { firstError = error }
                onError?(error)
            }

            if let firstError { return .failure(firstError) }
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
            completion.record(id: work.id, result: work.operation())
        }
    }

}
