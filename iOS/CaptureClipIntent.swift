import AppIntents
import OSLog
import UIKit

struct CaptureClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard to Yank"
    static let description = IntentDescription(
        "Saves the current clipboard text, or the text you pass in, to your Yank history."
    )
    static let openAppWhenRun = false

    /// How long `perform()` waits for the import and the sync push before it answers with what
    /// has been done so far. The work keeps going if iOS lets the process live on.
    static let postQueueTimeout: Duration = .seconds(20)
    private static let log = Logger(subsystem: "com.thepatientzero.yank", category: "shortcut")

    /// Text to save instead of reading the clipboard. A background run cannot always read the
    /// clipboard, so a shortcut can pass it in (for example from Get Clipboard).
    @Parameter(title: "Text")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) to Yank")
    }

    enum CaptureError: Error, LocalizedError {
        case noTextReceived
        case storageUnavailable
        case captureQueueFull
        case textTooLarge

        var errorDescription: String? {
            switch self {
            case .noTextReceived:
                return "No text was received. Pass text to this action with the Text input."
            case .storageUnavailable:
                return "Yank's storage is unavailable. Open Yank to check its status before retrying."
            case .captureQueueFull:
                return "Yank has pending captures. Open the app, then try again."
            case .textTooLarge:
                return "The clipboard text is too large to save."
            }
        }
    }

    /// What `perform()` can truthfully report once the clip is queued.
    enum CaptureResult: Equatable {
        case saved
        case savedSyncPending
        case queuedOnly

        var message: String {
            switch self {
            case .saved:
                return "Saved to Yank"
            case .savedSyncPending:
                return "Saved to Yank. Syncing to your other devices will finish when Yank next opens."
            case .queuedOnly:
                return "Saved. It will appear in Yank's history when Yank next opens."
            }
        }
    }

    struct QueuedCapture: Sendable {
        let entry: ShareCaptureInbox.Entry
        let inbox: ShareCaptureInbox
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let passedText = text
        let queued = try await Self.captureClipboard(
            resolveAppGroup: { AppGroupContainer.live() },
            readText: {
                if let passedText, !passedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return passedText
                }
                return UIPasteboard.general.string
            }
        )
        let result = await Self.importAndSync(queued)
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }

    @MainActor
    @discardableResult
    static func captureClipboard(
        resolveAppGroup: @MainActor () -> AppGroupContainer?,
        readText: @MainActor () -> String?
    ) async throws -> QueuedCapture {
        guard let appGroup = resolveAppGroup() else {
            throw CaptureError.storageUnavailable
        }
        guard let text = readText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.noTextReceived
        }
        let inbox = appGroup.shareInbox
        let entry = try await enqueue(text: text, in: inbox)
        return QueuedCapture(entry: entry, inbox: inbox)
    }

    @discardableResult
    nonisolated static func enqueue(text: String, in inbox: ShareCaptureInbox) async throws -> ShareCaptureInbox.Entry {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try inbox.enqueue(text: text, sourceApp: "Shortcuts")
            }.value
        } catch ShareCaptureInbox.Error.quotaExceeded {
            throw CaptureError.captureQueueFull
        } catch ShareCaptureInbox.Error.textTooLarge {
            throw CaptureError.textTooLarge
        } catch {
            logFailure("Queueing the clipboard text", error)
            throw CaptureError.storageUnavailable
        }
    }

    /// Writes the error domain and code only, never the clip text.
    private nonisolated static func logFailure(_ context: String, _ error: Error) {
        let nsError = error as NSError
        log.error(
            "\(context, privacy: .public) failed. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
    }

    // MARK: - After queuing

    /// How far the post-queue work got, shared between the work and the timeout so whichever
    /// finishes first answers once.
    @MainActor
    private final class PostQueueRun {
        enum Stage { case queued, imported, pushFailed, pushed }

        var stage: Stage = .queued
        var continuation: CheckedContinuation<CaptureResult, Never>?
        var timeout: Task<Void, Never>?

        var result: CaptureResult {
            switch stage {
            case .queued: return .queuedOnly
            case .imported, .pushFailed: return .savedSyncPending
            case .pushed: return .saved
            }
        }

        func finish(_ result: CaptureResult) {
            timeout?.cancel()
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// Imports the queued clip into history the way the app does when it opens, then pushes it to
    /// iCloud. The clip is already safe in the queue, so every failure here only changes what the
    /// answer says. A pending clip is imported (and pushed) by the app's next foreground refresh.
    @MainActor
    private static func importAndSync(_ queued: QueuedCapture) async -> CaptureResult {
        let run = PostQueueRun()
        return await withCheckedContinuation { continuation in
            run.continuation = continuation
            run.timeout = Task { @MainActor in
                do {
                    try await Task.sleep(for: postQueueTimeout)
                } catch {
                    return
                }
                run.finish(run.result)
            }
            Task { @MainActor in
                await importAndPush(queued, run: run)
            }
        }
    }

    @MainActor
    private static func importAndPush(_ queued: QueuedCapture, run: PostQueueRun) async {
        let runtime = IOSAppRuntime.shared
        let store = runtime.store
        await runtime.hydrate()
        // The same duties the foreground refresh does before it drains. Age retention is not
        // among them: it runs after the pull, so a clip another device used again is not expired.
        store.reconcileBackupExclusionInBackground()
        let sources = await store.drainShareInbox()
        // Otherwise the Shortcut method is never confirmed: the app's later drain finds nothing.
        runtime.settings.recordSuccessfulCaptureMethods(from: sources)

        // The drain's return value cannot tell imported from skipped; the processed record can.
        let entryID = queued.entry.id
        let inbox = queued.inbox
        let isImported: Bool
        do {
            isImported = try await Task.detached(priority: .userInitiated) {
                try inbox.isProcessed(entryID)
            }.value
        } catch {
            logFailure("Checking whether the clip was imported", error)
            isImported = false
        }
        guard isImported else {
            run.finish(.queuedOnly)
            return
        }
        run.stage = .imported
        guard runtime.settings.syncEnabled else {
            store.enforceRetentionAndLimit()
            run.stage = .pushed
            run.finish(.saved)
            return
        }
        let pullCountBefore = store.completedPullCount
        let outcome = await runtime.syncController.refreshForeground()
        // A pull that did not finish, when one could have, leaves the local history stale, so only
        // the cap applies.
        store.enforceRetentionAfterSyncRun(pullCountBefore: pullCountBefore, syncEnabled: true)
        run.stage = outcome == .failed ? .pushFailed : .pushed
        run.finish(run.result)
    }
}

struct YankShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureClipIntent(),
            phrases: [
                "Save clipboard to \(.applicationName)",
                "Capture clipboard in \(.applicationName)",
                "Add clipboard to \(.applicationName)",
                "Clip this with \(.applicationName)"
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "doc.on.clipboard"
        )
    }
}
