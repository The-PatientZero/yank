import Foundation

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
    private let historyURL: URL
    private let tombstonesURL: URL
    private let writeOptions: Data.WritingOptions
    private let filePermissions: Int?
    private let fileProtection: FileProtectionType?
    private let debounce: Duration
    private let queue: DispatchQueue
    private let onError: (@Sendable (Error) -> Void)?

    /// The most recent snapshot's write, kept until it is dispatched to `queue`.
    private var pendingWrite: (@Sendable () -> Void)?
    private var debounceTask: Task<Void, Never>?

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
    func scheduleSave(items: [ClipboardItem], tombstones: [UUID: Date]) {
        let historyURL = self.historyURL
        let tombstonesURL = self.tombstonesURL
        let writeOptions = self.writeOptions
        let filePermissions = self.filePermissions
        let fileProtection = self.fileProtection
        let onError = self.onError
        pendingWrite = {
            do {
                try JSONEncoder().encode(items).write(to: historyURL, options: writeOptions)
                try PrivateFileAttributes.apply(
                    to: historyURL,
                    permissions: filePermissions,
                    protection: fileProtection
                )
            } catch {
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
                    onError?(error)
                }
            }
        }

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

    /// Run any pending write now and block until the queue has drained it (plus any
    /// already-in-flight write). Synchronous, so callers can guarantee durability before
    /// the process suspends or terminates.
    func flush() {
        debounceTask?.cancel()
        debounceTask = nil
        dispatchPending()
        queue.sync {}   // barrier: wait for the serial queue to finish the write
    }

    private func dispatchPending() {
        debounceTask = nil
        guard let work = pendingWrite else { return }
        pendingWrite = nil
        queue.async(execute: work)
    }

}
