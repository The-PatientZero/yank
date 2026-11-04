import AppIntents
import OSLog
import UIKit

struct CaptureClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard to Yank"
    static let description = IntentDescription(
        "Saves the clipboard's text or image, or the text or image you pass in, to your Yank history."
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

    /// An image to save instead of reading the clipboard, for example from Get Clipboard or a
    /// photo. Used when no text is passed.
    @Parameter(title: "Image", supportedTypeIdentifiers: ["public.image"])
    var image: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) to Yank") {
            \.$image
        }
    }

    enum CaptureError: Error, LocalizedError {
        case noTextReceived
        case storageUnavailable
        case captureQueueFull
        case textTooLarge
        case imageUnreadable
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .noTextReceived:
                return "Nothing to save was received. Pass text or an image to this action."
            case .storageUnavailable:
                return "Yank's storage is unavailable. Open Yank to check its status before retrying."
            case .captureQueueFull:
                return "Yank has pending captures. Open the app, then try again."
            case .textTooLarge:
                return "The clipboard text is too large to save."
            case .imageUnreadable:
                return "The image couldn't be read. Pass it to this action with the Image input."
            case .imageTooLarge:
                return "The image is too large to save, or isn't an image Yank can read."
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
        /// The clipboard generation the clip was read from, when it came from the clipboard.
        var clipboardChangeCount: Int?
    }

    /// Passed text first, then a passed image, then the clipboard. The clipboard is saved as an
    /// image only when it holds one and no plain text, the rule automatic capture follows. When
    /// both inputs are passed and the clipboard holds an image, the image wins: Get Clipboard wired
    /// to both inputs turns a copied photo into its file name for the Text input.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let passedText = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let passedImage = image
        let pasteboard = UIPasteboard.general
        // Read before the clipboard is, so a later copy is never mistaken for the one saved.
        let clipboardChangeCount = pasteboard.changeCount
        let clipboardPrefersImage = PasteboardAcknowledgement.prefersImage(in: pasteboard.types)
        let readsClipboard = passedText == nil && passedImage == nil
        let savesImage = passedImage != nil && (passedText == nil || clipboardPrefersImage)
            || readsClipboard && clipboardPrefersImage
        var queued: QueuedCapture
        if savesImage {
            queued = try await Self.captureImage(
                resolveAppGroup: { AppGroupContainer.live() },
                readImage: {
                    if let passedImage {
                        if let fileURL = passedImage.fileURL {
                            return await PasteboardImageReader.normalize(fileAt: fileURL)
                        }
                        return await PasteboardImageReader.normalize(passedImage.data)
                    }
                    return await PasteboardImageReader.read(from: pasteboard, types: pasteboard.types)
                }
            )
        } else {
            do {
                queued = try await Self.captureClipboard(
                    resolveAppGroup: { AppGroupContainer.live() },
                    readText: { passedText ?? pasteboard.string }
                )
            } catch CaptureError.noTextReceived
                where readsClipboard && PasteboardAcknowledgement.declaresImage(in: pasteboard.types) {
                // Empty text beside an image: save the image, as automatic capture does.
                queued = try await Self.captureImage(
                    resolveAppGroup: { AppGroupContainer.live() },
                    readImage: { await PasteboardImageReader.read(from: pasteboard, types: pasteboard.types) }
                )
            }
        }
        if readsClipboard {
            queued.clipboardChangeCount = clipboardChangeCount
        }
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

    @MainActor
    static func captureImage(
        resolveAppGroup: @MainActor () -> AppGroupContainer?,
        readImage: @MainActor () async -> PasteboardImageReader.Result
    ) async throws -> QueuedCapture {
        guard let appGroup = resolveAppGroup() else {
            throw CaptureError.storageUnavailable
        }
        switch await readImage() {
        case .unreadable:
            throw CaptureError.imageUnreadable
        case .unsupported:
            throw CaptureError.imageTooLarge
        case let .png(pngData):
            let inbox = appGroup.shareInbox
            let entry = try await enqueue(imagePNG: pngData, in: inbox)
            return QueuedCapture(entry: entry, inbox: inbox)
        }
    }

    nonisolated static func enqueue(imagePNG pngData: Data, in inbox: ShareCaptureInbox) async throws -> ShareCaptureInbox.Entry {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try inbox.enqueue(imagePNG: pngData, sourceApp: "Shortcuts")
            }.value
        } catch ShareCaptureInbox.Error.quotaExceeded {
            throw CaptureError.captureQueueFull
        } catch ShareCaptureInbox.Error.payloadTooLarge {
            throw CaptureError.imageTooLarge
        } catch {
            logFailure("Queueing the image", error)
            throw CaptureError.storageUnavailable
        }
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
        // The same duties the foreground refresh does before it drains.
        store.enforceRetentionAndLimit()
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
        // The clipboard still holds what was saved, so opening Yank must not save it again.
        if let changeCount = queued.clipboardChangeCount, UIPasteboard.general.changeCount == changeCount {
            IOSForegroundRefreshCoordinator.shared.markPasteboardChangeHandled(changeCount)
        }
        run.stage = .imported
        guard runtime.settings.syncEnabled else {
            run.stage = .pushed
            run.finish(.saved)
            return
        }
        let outcome = await runtime.syncController.refreshForeground()
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
