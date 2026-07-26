import Foundation
import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

struct PasteboardChangeSuppression {
    private var generations: Set<Int> = []

    mutating func register(_ generation: Int) {
        generations.insert(generation)
    }

    mutating func shouldSuppress(_ observedGeneration: Int) -> Bool {
        generations = Set(generations.filter { $0 >= observedGeneration })
        return generations.remove(observedGeneration) != nil
    }
}

protocol PasteboardPayloadReading: AnyObject {
    var changeCount: Int { get }
    var typeIdentifiers: [String] { get }

    func filePaths() -> [String]?
    func data(forType identifier: String) -> Data?
}

private final class AppKitPasteboardPayloadReader: PasteboardPayloadReading {
    private let pasteboard: NSPasteboard
    private let item: NSPasteboardItem?

    init(name: NSPasteboard.Name) {
        let pasteboard = NSPasteboard(name: name)
        self.pasteboard = pasteboard
        self.item = pasteboard.pasteboardItems?.first
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var typeIdentifiers: [String] {
        (item?.types ?? pasteboard.types ?? []).map(\.rawValue)
    }

    func filePaths() -> [String]? {
        pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String]
    }

    func data(forType identifier: String) -> Data? {
        let type = NSPasteboard.PasteboardType(identifier)
        return item?.data(forType: type) ?? pasteboard.data(forType: type)
    }
}

enum PasteboardPayload: Equatable, Sendable {
    case filePaths([String])
    case text(String, richArchive: PasteboardArchive?)
    case image(Data, richArchive: PasteboardArchive?)
    case unsupported

    var retainedByteCount: Int {
        switch self {
        case .filePaths(let paths):
            paths.reduce(0) { $0 + $1.utf8.count }
        case .text(let text, let archive):
            text.utf8.count + (archive?.totalBytes ?? 0)
        case .image(let data, let archive):
            data.count + (archive?.totalBytes ?? 0)
        case .unsupported:
            0
        }
    }
}

struct PasteboardPayloadSnapshot: Equatable, Sendable {
    let generation: Int
    let payload: PasteboardPayload
}

enum PasteboardPayloadMaterializer {
    struct Limits: Equatable, Sendable {
        let maxTextBytes: Int
        let maxImageBytes: Int
        let maxRichRepresentationBytes: Int
        let maxRichArchiveBytes: Int
        let maxPayloadBytes: Int
        let maxTypeCount: Int
        let maxTypeIdentifierBytes: Int
        let maxFileCount: Int
        let maxFilePathBytes: Int

        static let capture = Limits(
            maxTextBytes: SyncBlobKind.text.maximumBytes,
            maxImageBytes: SyncBlobKind.image.maximumBytes,
            maxRichRepresentationBytes: SyncBlobKind.rich.maximumBytes,
            maxRichArchiveBytes: SyncBlobKind.rich.maximumBytes,
            maxPayloadBytes: SyncBlobKind.image.maximumBytes + SyncBlobKind.rich.maximumBytes,
            maxTypeCount: 256,
            maxTypeIdentifierBytes: 1_024,
            maxFileCount: CapturePolicy.maxFileListEntries,
            maxFilePathBytes: CapturePolicy.maxFilePathLength
        )
    }

    nonisolated static func materialize(
        pasteboardName: String,
        expectedGeneration: Int,
        limits: Limits = .capture
    ) -> PasteboardPayloadSnapshot? {
        let reader = AppKitPasteboardPayloadReader(
            name: NSPasteboard.Name(pasteboardName)
        )
        return materialize(
            reader: reader,
            expectedGeneration: expectedGeneration,
            limits: limits
        )
    }

    nonisolated static func materialize(
        reader: PasteboardPayloadReading,
        expectedGeneration: Int,
        limits: Limits
    ) -> PasteboardPayloadSnapshot? {
        guard reader.changeCount == expectedGeneration else { return nil }

        let typeIdentifiers = reader.typeIdentifiers
        guard typeIdentifiers.count <= limits.maxTypeCount,
              typeIdentifiers.allSatisfy({
                  $0.utf8.count <= limits.maxTypeIdentifierBytes
              }),
              !typeIdentifiers.contains(where: ConcealedPasteboardType.all.contains) else {
            return nil
        }

        var cachedRepresentations: [String: Data] = [:]
        let payload: PasteboardPayload

        if let filePaths = reader.filePaths(), !filePaths.isEmpty {
            guard filePaths.count <= limits.maxFileCount,
                  filePaths.allSatisfy({ $0.utf8.count <= limits.maxFilePathBytes }) else {
                payload = .unsupported
                return stableSnapshot(
                    generation: expectedGeneration,
                    payload: payload,
                    reader: reader,
                    limits: limits
                )
            }
            payload = .filePaths(filePaths)
        } else if let textData = reader.data(forType: NSPasteboard.PasteboardType.string.rawValue) {
            guard textData.count <= limits.maxTextBytes else {
                payload = .unsupported
                return stableSnapshot(
                    generation: expectedGeneration,
                    payload: payload,
                    reader: reader,
                    limits: limits
                )
            }
            cachedRepresentations[NSPasteboard.PasteboardType.string.rawValue] = textData
            if let text = String(data: textData, encoding: .utf8), !text.isEmpty {
                payload = .text(
                    text,
                    richArchive: richArchive(
                        reader: reader,
                        typeIdentifiers: typeIdentifiers,
                        cachedRepresentations: &cachedRepresentations,
                        limits: limits
                    )
                )
            } else {
                payload = imagePayload(
                    reader: reader,
                    typeIdentifiers: typeIdentifiers,
                    cachedRepresentations: &cachedRepresentations,
                    limits: limits
                )
            }
        } else {
            payload = imagePayload(
                reader: reader,
                typeIdentifiers: typeIdentifiers,
                cachedRepresentations: &cachedRepresentations,
                limits: limits
            )
        }

        return stableSnapshot(
            generation: expectedGeneration,
            payload: payload,
            reader: reader,
            limits: limits
        )
    }

    private nonisolated static func imagePayload(
        reader: PasteboardPayloadReading,
        typeIdentifiers: [String],
        cachedRepresentations: inout [String: Data],
        limits: Limits
    ) -> PasteboardPayload {
        for identifier in [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue
        ] {
            guard let data = reader.data(forType: identifier) else { continue }
            guard data.count <= limits.maxImageBytes else { return .unsupported }
            cachedRepresentations[identifier] = data
            return .image(
                data,
                richArchive: richArchive(
                    reader: reader,
                    typeIdentifiers: typeIdentifiers,
                    cachedRepresentations: &cachedRepresentations,
                    limits: limits
                )
            )
        }
        return .unsupported
    }

    private nonisolated static func richArchive(
        reader: PasteboardPayloadReading,
        typeIdentifiers: [String],
        cachedRepresentations: inout [String: Data],
        limits: Limits
    ) -> PasteboardArchive? {
        guard PasteboardArchive.isRich(utis: typeIdentifiers) else { return nil }

        var totalBytes = 0
        var representations: [PasteboardArchive.Representation] = []
        representations.reserveCapacity(typeIdentifiers.count)

        for identifier in typeIdentifiers {
            let data: Data
            if let cached = cachedRepresentations[identifier] {
                data = cached
            } else if let loaded = reader.data(forType: identifier) {
                data = loaded
                cachedRepresentations[identifier] = loaded
            } else {
                continue
            }

            guard data.count <= limits.maxRichRepresentationBytes,
                  data.count <= limits.maxRichArchiveBytes - totalBytes else {
                return nil
            }
            totalBytes += data.count
            representations.append(.init(uti: identifier, data: data))
        }

        return representations.isEmpty ? nil : PasteboardArchive(representations: representations)
    }

    private nonisolated static func stableSnapshot(
        generation: Int,
        payload: PasteboardPayload,
        reader: PasteboardPayloadReading,
        limits: Limits
    ) -> PasteboardPayloadSnapshot? {
        guard reader.changeCount == generation,
              payload.retainedByteCount <= limits.maxPayloadBytes else {
            return nil
        }
        return PasteboardPayloadSnapshot(generation: generation, payload: payload)
    }
}

@MainActor
final class SerialCaptureQueue<Value: Sendable> {
    typealias Loader = @Sendable () async -> Value?
    typealias Apply = @MainActor @Sendable (Value) async -> Void

    private var epoch = 0
    private var tail: Task<Void, Never>?
    private var loaderTasks: [UUID: Task<Value?, Never>] = [:]
    private var applicationTasks: [UUID: Task<Void, Never>] = [:]

    func enqueue(loader: @escaping Loader, apply: @escaping Apply) {
        let id = UUID()
        let enqueueEpoch = epoch
        let previousApplication = tail
        let loaderTask = Task.detached(priority: .utility) {
            await loader()
        }
        loaderTasks[id] = loaderTask

        let applicationTask = Task { [weak self, loaderTask, previousApplication] in
            let value = await loaderTask.value
            await previousApplication?.value

            guard let self,
                  !Task.isCancelled,
                  self.epoch == enqueueEpoch,
                  let value else {
                self?.finish(id: id)
                return
            }

            await apply(value)
            self.finish(id: id)
        }
        applicationTasks[id] = applicationTask
        tail = applicationTask
    }

    func cancelAll() {
        epoch &+= 1
        loaderTasks.values.forEach { $0.cancel() }
        applicationTasks.values.forEach { $0.cancel() }
        loaderTasks.removeAll()
        applicationTasks.removeAll()
        tail = nil
    }

    func waitUntilIdle() async {
        let currentTail = tail
        await currentTail?.value
    }

    private func finish(id: UUID) {
        loaderTasks[id] = nil
        applicationTasks[id] = nil
    }
}

private enum PreparedClipboardCapture: Sendable {
    case fileText(String, sourceApp: String?)
    case text(
        TextCapturePlan,
        originalText: String,
        richArchive: PasteboardArchive?,
        sourceApp: String?,
        generation: Int,
        observedAt: Date
    )
    case image(Data, richArchive: PasteboardArchive?, sourceApp: String?)
    case unsupported
}

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
    private nonisolated static let maxImageInputBytes = 32 * 1024 * 1024
    private nonisolated static let maxRasterPixels: Int64 = 40_000_000
    
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
                    sourceApp: observedAppName,
                    observedBundleID: observedBundleID,
                    observedAt: observedAt,
                    settings: settings
                )
            },
            apply: { [weak self] capture in
                guard let self else { return }
                await self.apply(capture)
            }
        )
    }

    private nonisolated static func prepareCapture(
        _ snapshot: PasteboardPayloadSnapshot,
        sourceApp: String?,
        observedBundleID: String?,
        observedAt: Date,
        settings: CaptureSettings
    ) -> PreparedClipboardCapture {
        switch snapshot.payload {
        case .filePaths(let rawFilePaths):
            let policy = CapturePolicy(excludedBundleIDs: settings.excludedBundleIDs)
            let filePaths: [String]
            switch policy.decideFileListCapture(
                frontmostBundleID: observedBundleID,
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
                return .image(capture.pngData, richArchive: nil, sourceApp: sourceApp)
            }
            return .fileText(filePaths.joined(separator: "\n"), sourceApp: sourceApp)

        case .text(let text, let archive):
            guard CapturePolicy.meetsMinimumLength(text, minLength: settings.minCaptureLength) else {
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
                richArchive: archive,
                sourceApp: sourceApp,
                generation: snapshot.generation,
                observedAt: observedAt
            )

        case .image(let imageData, let archive):
            guard case .image(let pngData, let retainedArchive) = normalizedImagePayload(
                from: imageData,
                richArchive: archive,
                limits: .capture,
                maxRasterPixels: maxRasterPixels,
                sourceDescription: "pasteboard image"
            ) else {
                return .unsupported
            }
            return .image(pngData, richArchive: retainedArchive, sourceApp: sourceApp)

        case .unsupported:
            return .unsupported
        }
    }

    private func apply(_ capture: PreparedClipboardCapture) async {
        guard !Task.isCancelled else { return }

        switch capture {
        case .fileText(let summary, let sourceApp):
            store.add(ClipboardItem.text(summary, sourceApp: sourceApp))

        case .text(
            let plan,
            let originalText,
            let archive,
            let sourceApp,
            let generation,
            let observedAt
        ):
            onEligibleTextCopy?(generation, originalText, observedAt)
            let isRich = archive != nil

            switch plan.storage {
            case .inline(let content):
                var item = ClipboardItem.text(content, sourceApp: sourceApp)
                item.hasRichContent = isRich
                await store.addCaptured(item, primaryBlob: nil, richArchive: archive)
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
                    richArchive: archive
                )
            case .truncated(let preview, let originalSizeBytes):
                var item = ClipboardItem.truncatedText(
                    preview: preview,
                    originalSizeBytes: originalSizeBytes,
                    sourceApp: sourceApp
                )
                item.hasRichContent = isRich
                await store.addCaptured(item, primaryBlob: nil, richArchive: archive)
            }

        case .image(let pngData, let archive, let sourceApp):
            var item = ClipboardItem(type: .image, sourceApp: sourceApp)
            item.hasRichContent = archive != nil
            await store.addCaptured(
                item,
                primaryBlob: .image(pngData),
                richArchive: archive
            )

        case .unsupported:
            break
        }
    }
    
    /// Check if a file path points to an image by examining its UTType
    private nonisolated static func isImageFile(_ filePath: String) -> Bool {
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        
        if let utType = UTType(filenameExtension: fileExtension) {
            return utType.conforms(to: .image)
        }
        return false
    }
    
    private struct ImageFileCapture: Sendable {
        let pngData: Data
    }

    /// Read image file from disk and normalize to PNG. Runs off the main actor.
    private nonisolated static func imageFileCapture(_ filePath: String) -> ImageFileCapture? {
        do {
            let fileURL = URL(fileURLWithPath: filePath)
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
                Log.capture.error("Skipping non-regular image file from pasteboard file list")
                return nil
            }
            if let size = resourceValues.fileSize, size > Self.maxImageInputBytes {
                Log.capture.error("Skipping oversized image file from pasteboard file list")
                return nil
            }
            let fileData = try Data(contentsOf: fileURL)
            
            guard let pngData = Self.normalizedPNGData(
                from: fileData,
                maxInputBytes: Self.maxImageInputBytes,
                maxRasterPixels: Self.maxRasterPixels,
                sourceDescription: filePath
            ) else {
                Log.capture.error("Failed to convert image file from pasteboard file list")
                return nil
            }
            
            return ImageFileCapture(pngData: pngData)
        } catch {
            Log.capture.error("Error processing image file from pasteboard file list: \(error.localizedDescription)")
            return nil
        }
    }

    /// Normalise arbitrary raster bytes to PNG using a single `CGImageSource` for both the
    /// pixel-budget check and the re-encode: no TIFF/bitmap round-trip, one
    /// decode, no uncompressed-bitmap allocation. Off the main actor.
    nonisolated static func normalizedPNGData(
        from data: Data,
        maxInputBytes: Int,
        maxOutputBytes: Int = SyncBlobKind.image.maximumBytes,
        maxRasterPixels: Int64,
        sourceDescription: String,
        encoder: @Sendable (CGImage) -> Data? = PNGEncoder.encode
    ) -> Data? {
        guard data.count <= maxInputBytes else {
            Log.capture.error("Skipping oversized image data: \(sourceDescription)")
            return nil
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        guard pixelCountIsWithinBudget(source, maxRasterPixels: maxRasterPixels) else {
            Log.capture.error("Skipping image with too many pixels: \(sourceDescription)")
            return nil
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let pngData = encoder(cgImage),
              !pngData.isEmpty,
              pngData.count <= maxOutputBytes else {
            Log.capture.error("Skipping image whose normalized PNG exceeds the byte budget: \(sourceDescription)")
            return nil
        }
        return pngData
    }

    nonisolated static func normalizedImagePayload(
        from data: Data,
        richArchive: PasteboardArchive?,
        limits: PasteboardPayloadMaterializer.Limits,
        maxRasterPixels: Int64,
        sourceDescription: String,
        encoder: @Sendable (CGImage) -> Data? = PNGEncoder.encode
    ) -> PasteboardPayload {
        guard let pngData = normalizedPNGData(
            from: data,
            maxInputBytes: limits.maxImageBytes,
            maxOutputBytes: limits.maxImageBytes,
            maxRasterPixels: maxRasterPixels,
            sourceDescription: sourceDescription,
            encoder: encoder
        ) else {
            return .unsupported
        }
        let archiveBytes = richArchive?.totalBytes ?? 0
        guard archiveBytes <= limits.maxPayloadBytes,
              pngData.count <= limits.maxPayloadBytes - archiveBytes else {
            Log.capture.error("Skipping normalized image whose retained payload exceeds the aggregate byte budget")
            return .unsupported
        }
        return .image(pngData, richArchive: richArchive)
    }

    /// True when the first image in `source` is within the pixel budget. Lenient when the
    /// dimensions can't be read (no properties / zero size) — defers the reject to the
    /// decode step, preserving the previous fail-open behaviour for odd encodings.
    private nonisolated static func pixelCountIsWithinBudget(
        _ source: CGImageSource,
        maxRasterPixels: Int64
    ) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return true
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return true }
        return Int64(width) * Int64(height) <= maxRasterPixels
    }
}
