import Foundation

/// Keeps Yank's iOS history storage out of device backups unless the user opted in.
///
/// iOS treats `isExcludedFromBackup` as guidance, and a flag on a file belongs to that file, so
/// rewriting a file in place can drop it. `reconcile()` therefore re-applies the wanted state to
/// every item and is safe to call as often as needed, from any thread. It reads the setting at
/// the moment it runs, under a lock, so whichever call runs last converges on the latest choice.
final class BackupExclusion: Sendable {
    // UserDefaults is documented as thread-safe but is not annotated Sendable in this SDK.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let files: [URL]
    private let directories: [URL]
    private let lock = NSLock()

    init(context: AppGroupContext) {
        let inbox = context.shareInbox
        self.defaults = context.defaults
        // The history transaction file is a full copy of the history while a write is in flight.
        self.files = [
            context.historyURL,
            HistorySnapshotTransaction.transactionURL(for: context.historyURL),
            context.tombstonesURL,
            context.keyboardProjectionURL,
            inbox.processedURL
        ]
        // A flag on a directory covers what is inside it, so new blobs and inbox entries need no
        // marking of their own.
        self.directories = [context.blobsURL, inbox.entriesURL, inbox.payloadsURL]
    }

    /// Creates the folders when missing, then sets or clears the exclusion on every existing item.
    /// A failure is logged and retried by the next call; it never disables history storage.
    func reconcile() {
        lock.lock()
        defer { lock.unlock() }

        let excluded = !defaults.bool(forKey: SettingsKeys.includeHistoryInBackups)
        let fileManager = FileManager.default
        for directory in directories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                clipStoreLog.error(
                    "Failed to create \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
        for url in files + directories where fileManager.fileExists(atPath: url.path) {
            apply(excluded: excluded, to: url)
        }
    }

    private func apply(excluded: Bool, to url: URL) {
        do {
            // A URL caches resource values, and a replaced file keeps the stale answer.
            var target = url
            target.removeAllCachedResourceValues()
            let current = try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            guard current != excluded else { return }
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try target.setResourceValues(values)
        } catch {
            clipStoreLog.error(
                "Failed to update backup exclusion for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
            )
        }
    }
}
