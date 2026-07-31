import Foundation
import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Monitors the system clipboard for changes and captures new content
@MainActor
@Observable
final class ClipboardWatcher {
    private(set) var isPaused = false

    private let store: ClipboardStore

    /// Injected capture-relevant settings: the excluded-app set and the
    /// minimum capture length, read on the capture path instead of from the
    /// `SettingsManager.shared` singleton, so capture is testable in isolation. The
    /// composition root re-assigns this when the user changes either setting.
    var captureSettings: CaptureSettings

    private var timer: Timer?
    private var wantsWatching = false
    private var lastChangeCount: Int = 0
    @ObservationIgnored private let captureQueue = SerialCaptureQueue<PreparedClipboardCapture>()
    private var changeSuppression = PasteboardChangeSuppression()

    /// Reports eligible text occurrences before durable-history deduplication.
    var onEligibleTextCopy: ((Int, String, Date) -> Void)?

    private(set) var ignoreNextChange = false

    private static let normalPollInterval: TimeInterval = 0.5
    private static let sequencePollInterval: TimeInterval = 0.1
    private var sequenceCollectionActive = false

    // Size thresholds for text handling
    private nonisolated static let inlineTextLimit = 50_000
    private nonisolated static let previewLength = 500
    nonisolated static let maxImageInputBytes = 32 * 1024 * 1024
    nonisolated static let maxRasterPixels: Int64 = 40_000_000

    init(store: ClipboardStore, settings: CaptureSettings) {
        self.store = store
        self.captureSettings = settings
        self.lastChangeCount = NSPasteboard.general.changeCount

        // Listen for ignore notification (when copying from history)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIgnoreNextChange(_:)),
            name: .yankIgnoreNextChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleIgnoreNextChange(_ notification: Notification) {
        guard let receipt = notification.object as? PasteboardWriteReceipt,
              receipt.pasteboardName == NSPasteboard.Name.general.rawValue else {
            return
        }
        changeSuppression.register(receipt.generation)
    }

    func startWatching() {
        wantsWatching = true
        installTimerIfNeeded()
    }

    private func installTimerIfNeeded() {
        guard wantsWatching, !isPaused, timer == nil else { return }

        let pollInterval = Self.pollInterval(sequenceCollectionActive: sequenceCollectionActive)
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
        // Let the OS coalesce our wakeups with other timers to save power on this
        // always-on background poll; 0.1 s slack is imperceptible for clipboard capture.
        timer.tolerance = pollInterval / 5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopWatching() {
        wantsWatching = false
        invalidateTimer()
        captureQueue.cancelAll()
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    func pause() {
        isPaused = true
        invalidateTimer()
        captureQueue.cancelAll()
    }

    func resume() {
        isPaused = false
        lastChangeCount = NSPasteboard.general.changeCount
        installTimerIfNeeded()
    }

    func setSequenceCollectionActive(_ isActive: Bool) {
        guard sequenceCollectionActive != isActive else { return }
        sequenceCollectionActive = isActive
        guard wantsWatching, !isPaused else { return }
        invalidateTimer()
        installTimerIfNeeded()
    }

    static func pollInterval(sequenceCollectionActive: Bool) -> TimeInterval {
        sequenceCollectionActive ? sequencePollInterval : normalPollInterval
    }

    func ignoreNextCopy() {
        ignoreNextChange.toggle()
    }

    private func checkClipboard() {
        guard !isPaused else { return }

        let currentChangeCount = NSPasteboard.general.changeCount

        // No change detected
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        // App-owned writes identify the exact pasteboard generation they created. A newer
        // user copy must still be captured even if the watcher did not poll in between.
        if changeSuppression.shouldSuppress(currentChangeCount) { return }

        // The explicit user-facing "ignore next copy" action remains a one-change arm.
        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let observedAppName = frontmostApp?.localizedName
        let observedBundleID = frontmostApp?.bundleIdentifier
        // AppKit does not expose an authenticated pasteboard writer. The observed app is
        // display attribution and a best-effort privacy hint, not a trusted source identity.

        // Privacy guard: never record concealed/secret copies or excluded apps.
        let settings = captureSettings
        let policy = CapturePolicy(excludedBundleIDs: settings.excludedBundleIDs)
        guard policy.decide(frontmostBundleID: observedBundleID, pasteboardTypes: []) == .capture else {
            return
        }

        let pasteboardName = NSPasteboard.Name.general.rawValue
        let observedAt = Date()
        captureQueue.enqueue(
            loader: {
                guard !Task.isCancelled,
                      let snapshot = PasteboardPayloadMaterializer.materialize(
                          pasteboardName: pasteboardName,
                          expectedGeneration: currentChangeCount
                      ),
                      !Task.isCancelled else {
                    return nil
                }
                return Self.prepareCapture(
                    snapshot,
                    context: ClipboardCaptureContext(
                        sourceApp: observedAppName,
                        observedBundleID: observedBundleID,
                        observedAt: observedAt,
                        settings: settings
                    )
                )
            },
            apply: { [weak self] capture in
                guard let self else { return }
                await self.apply(capture)
            }
        )
    }
}

private extension ClipboardWatcher {
    private nonisolated static func prepareCapture(
        _ snapshot: PasteboardPayloadSnapshot,
        context: ClipboardCaptureContext
    ) -> PreparedClipboardCapture {
        switch snapshot.payload {
        case .filePaths(let rawFilePaths):
            return prepareFileCapture(rawFilePaths, context: context)

        case .text(let text, let archive):
            return prepareTextCapture(
                text,
                snapshotGeneration: snapshot.generation,
                richArchive: archive,
                context: context
            )

        case .image(let imageData, let archive):
            return prepareImageCapture(
                imageData,
                richArchive: archive,
                context: context
            )

        case .unsupported:
            return .unsupported
        }
    }

    private nonisolated static func prepareFileCapture(
        _ rawFilePaths: [String],
        context: ClipboardCaptureContext
    ) -> PreparedClipboardCapture {
        let policy = CapturePolicy(excludedBundleIDs: context.settings.excludedBundleIDs)
        let filePaths: [String]
        switch policy.decideFileListCapture(
            frontmostBundleID: context.observedBundleID,
            filePaths: rawFilePaths
        ) {
        case .capture(let normalizedPaths):
            filePaths = normalizedPaths
        case .skipEmpty:
            return .unsupported
        case .skipUntrustedSource(let bundleID):
            Log.capture.info(
                "Skipping file-list pasteboard from untrusted observed app: \(bundleID ?? "unknown")"
            )
            return .unsupported
        case .skipInvalidPaths:
            Log.capture.info("Skipping invalid file-list pasteboard")
            return .unsupported
        }

        if filePaths.count == 1,
           let filePath = filePaths.first,
           isImageFile(filePath) {
            guard let capture = imageFileCapture(filePath) else { return .unsupported }
            return .image(
                capture.pngData,
                richArchive: nil,
                sourceApp: context.sourceApp,
                observedAt: context.observedAt
            )
        }
        return .fileText(
            filePaths.joined(separator: "\n"),
            sourceApp: context.sourceApp,
            observedAt: context.observedAt
        )
    }

    private nonisolated static func prepareTextCapture(
        _ text: String,
        snapshotGeneration: Int,
        richArchive: PasteboardArchive?,
        context: ClipboardCaptureContext
    ) -> PreparedClipboardCapture {
        guard CapturePolicy.meetsMinimumLength(
            text,
            minLength: context.settings.minCaptureLength
        ) else {
            return .unsupported
        }
        return .text(
            TextCapturePlan.make(
                for: text,
                inlineLimit: inlineTextLimit,
                previewLength: previewLength,
                maxStoredBytes: SyncBlobKind.text.maximumBytes
            ),
            originalText: text,
            richArchive: richArchive,
            sourceApp: context.sourceApp,
            generation: snapshotGeneration,
            observedAt: context.observedAt
        )
    }

    private nonisolated static func prepareImageCapture(
        _ imageData: Data,
        richArchive: PasteboardArchive?,
        context: ClipboardCaptureContext
    ) -> PreparedClipboardCapture {
        guard case .image(let pngData, let retainedArchive) = normalizedImagePayload(
            from: imageData,
            richArchive: richArchive,
            limits: .capture,
            maxRasterPixels: maxRasterPixels,
            sourceDescription: "pasteboard image"
        ) else {
            return .unsupported
        }
        return .image(
            pngData,
            richArchive: retainedArchive,
            sourceApp: context.sourceApp,
            observedAt: context.observedAt
        )
    }

    private func apply(_ capture: PreparedClipboardCapture) async {
        guard !Task.isCancelled else { return }

        switch capture {
        case .fileText(let summary, let sourceApp, let observedAt):
            store.add(
                ClipboardItem.text(summary, sourceApp: sourceApp),
                observedAt: observedAt
            )

        case .text(
            let plan,
            let originalText,
            let archive,
            let sourceApp,
            let generation,
            let observedAt
        ):
            onEligibleTextCopy?(generation, originalText, observedAt)
            await applyTextCapture(
                plan,
                richArchive: archive,
                sourceApp: sourceApp,
                observedAt: observedAt
            )

        case .image(let pngData, let archive, let sourceApp, let observedAt):
            var item = ClipboardItem(type: .image, sourceApp: sourceApp)
            item.hasRichContent = archive != nil
            await store.addCaptured(
                item,
                primaryBlob: .image(pngData),
                richArchive: archive,
                observedAt: observedAt
            )

        case .unsupported:
            break
        }
    }

    private func applyTextCapture(
        _ plan: TextCapturePlan,
        richArchive: PasteboardArchive?,
        sourceApp: String?,
        observedAt: Date
    ) async {
        let isRich = richArchive != nil
        switch plan.storage {
        case .inline(let content):
            var item = ClipboardItem.text(content, sourceApp: sourceApp)
            item.hasRichContent = isRich
            await store.addCaptured(
                item,
                primaryBlob: nil,
                richArchive: richArchive,
                observedAt: observedAt
            )
        case .fileBacked(let preview, let fullText, let originalSizeBytes, let searchIndex):
            var item = ClipboardItem(
                type: .text,
                sourceApp: sourceApp,
                textContent: preview,
                originalSizeBytes: originalSizeBytes,
                searchIndex: searchIndex
            )
            item.hasRichContent = isRich
            await store.addCaptured(
                item,
                primaryBlob: .text(fullText),
                richArchive: richArchive,
                observedAt: observedAt
            )
        case .truncated(let preview, let originalSizeBytes):
            var item = ClipboardItem.truncatedText(
                preview: preview,
                originalSizeBytes: originalSizeBytes,
                sourceApp: sourceApp
            )
            item.hasRichContent = isRich
            await store.addCaptured(
                item,
                primaryBlob: nil,
                richArchive: richArchive,
                observedAt: observedAt
            )
        }
    }
}
