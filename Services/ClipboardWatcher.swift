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
    private var lastContentFingerprint: ClipboardContentFingerprint?
    private var textCaptureChain: Task<Void, Never>?
    private var changeSuppression = PasteboardChangeSuppression()
    private var newestExactSuppressionGeneration: Int?

    private(set) var ignoreNextChange = false

    private let pollInterval: TimeInterval = 0.5
    
    // Size thresholds for text handling
    private let inlineTextLimit = 50_000       // 50 KB — store inline
    private let previewLength = 500            // Characters kept as inline preview
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
        if let generation = notification.object as? Int {
            changeSuppression.register(generation)
            newestExactSuppressionGeneration = max(newestExactSuppressionGeneration ?? generation, generation)
            return
        }

        // Older synchronous callers announce immediately before writing. Observe their
        // resulting generation on the next main-queue turn without arming a broad skip.
        let generationBeforeWrite = NSPasteboard.general.changeCount
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let newestExactGeneration = self.newestExactSuppressionGeneration ?? generationBeforeWrite
            guard newestExactGeneration <= generationBeforeWrite else { return }
            let generationAfterWrite = NSPasteboard.general.changeCount
            guard generationAfterWrite != generationBeforeWrite else { return }
            self.changeSuppression.register(generationAfterWrite)
        }
    }
    
    func startWatching() {
        wantsWatching = true
        installTimerIfNeeded()
    }

    private func installTimerIfNeeded() {
        guard wantsWatching, !isPaused, timer == nil else { return }

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
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    func pause() {
        isPaused = true
        invalidateTimer()
    }
    
    func resume() {
        isPaused = false
        lastChangeCount = NSPasteboard.general.changeCount
        installTimerIfNeeded()
    }

    func ignoreNextCopy() {
        ignoreNextChange.toggle()
    }
    
    private func checkClipboard() {
        guard !isPaused else { return }

        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

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
        let policy = CapturePolicy(excludedBundleIDs: captureSettings.excludedBundleIDs)
        let pasteboardTypes = pasteboard.types?.map(\.rawValue) ?? []
        guard policy.decide(frontmostBundleID: observedBundleID,
                            pasteboardTypes: pasteboardTypes) == .capture else { return }

        // Dispatch to the first capture path that applies. Files are tried before text
        // because Finder also writes .string alongside the file list.
        if captureFiles(from: pasteboard,
                        sourceApp: observedAppName,
                        policy: policy,
                        observedBundleID: observedBundleID) { return }
        if captureText(from: pasteboard, sourceApp: observedAppName) { return }
        captureImage(from: pasteboard, sourceApp: observedAppName)
    }

    /// Finder file copies (NSFilenamesPboardType): a single image file becomes an image
    /// clip; any other file copy is captured as a text clip listing the paths (#11).
    /// Returns true if the change was a file copy (so the caller stops here).
    private func captureFiles(
        from pasteboard: NSPasteboard,
        sourceApp: String?,
        policy: CapturePolicy,
        observedBundleID: String?
    ) -> Bool {
        guard let rawFilePaths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !rawFilePaths.isEmpty else {
            return false
        }

        let filePaths: [String]
        switch policy.decideFileListCapture(frontmostBundleID: observedBundleID, filePaths: rawFilePaths) {
        case .capture(let normalizedPaths):
            filePaths = normalizedPaths
        case .skipEmpty:
            return false
        case .skipUntrustedSource(let bundleID):
            Log.capture.info("Skipping file-list pasteboard from untrusted observed app: \(bundleID ?? "unknown")")
            return true
        case .skipInvalidPaths:
            Log.capture.info("Skipping invalid file-list pasteboard")
            return true
        }

        if filePaths.count == 1, let filePath = filePaths.first, isImageFile(filePath) {
            // Read + normalise the file off the main actor (structured concurrency, mirroring
            // OCRService), then hop back to apply the capture.
            Task { [weak self] in
                guard let capture = await Task.detached(priority: .userInitiated, operation: {
                    Self.imageFileCapture(filePath, sourceApp: sourceApp)
                }).value else { return }
                guard let self, self.markContentFingerprintIfNew(capture.fingerprint) else { return }
                if let filename = self.store.saveImage(capture.pngData) {
                    self.store.add(capture.item(with: filename))
                }
            }
            return true
        }

        let summary = filePaths.joined(separator: "\n")
        if markContentFingerprintIfNew(.fileList(summary)) {
            store.add(ClipboardItem.text(summary, sourceApp: sourceApp))
        }
        return true
    }

    /// Plain or rich text on the pasteboard. Small text is stored inline; large text is
    /// written to a file with an inline preview. Returns true if there was text (even if it
    /// was filtered by the min-length rule or a consecutive duplicate), so the caller stops.
    private func captureText(from pasteboard: NSPasteboard, sourceApp: String?) -> Bool {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }

        // Min-length filter is a pure, tested policy in YankCore; below threshold
        // counts as "handled" so the caller stops walking pasteboard types.
        guard CapturePolicy.meetsMinimumLength(text, minLength: captureSettings.minCaptureLength) else {
            return true
        }

        let archive = captureRichArchive(from: pasteboard)
        let isRich = archive != nil

        let previousCapture = textCaptureChain
        let task = Task { [weak self, previousCapture] in
            await previousCapture?.value

            let inlineTextLimit = self?.inlineTextLimit ?? 50_000
            let previewLength = self?.previewLength ?? 500
            let plan = await Task.detached(priority: .userInitiated) {
                TextCapturePlan.make(
                    for: text,
                    inlineLimit: inlineTextLimit,
                    previewLength: previewLength,
                    maxStoredBytes: SyncBlobKind.text.maximumBytes
                )
            }.value

            guard let self, self.markContentFingerprintIfNew(plan.fingerprint) else { return }

            switch plan.storage {
            case .inline(let content):
                var item = ClipboardItem.text(content, sourceApp: sourceApp)
                item.hasRichContent = isRich
                self.store.add(item, richArchive: archive)
            case .fileBacked(let preview, let fullText, let originalSizeBytes, let searchIndex):
                guard let filename = await self.store.saveTextAsync(fullText) else { return }
                var item = ClipboardItem.largeText(
                    preview: preview,
                    filename: filename,
                    sourceApp: sourceApp,
                    originalSizeBytes: originalSizeBytes,
                    searchIndex: searchIndex
                )
                item.hasRichContent = isRich
                self.store.add(item, richArchive: archive)
            case .truncated(let preview, let originalSizeBytes):
                var item = ClipboardItem.truncatedText(
                    preview: preview,
                    originalSizeBytes: originalSizeBytes,
                    sourceApp: sourceApp
                )
                item.hasRichContent = isRich
                self.store.add(item, richArchive: archive)
            }
        }
        textCaptureChain = task
        return true
    }

    /// A raster image on the pasteboard (png/tiff). Normalised to PNG off the main actor;
    /// vector copies carry PDF alongside the raster, so the rich archive is captured too.
    private func captureImage(from pasteboard: NSPasteboard, sourceApp: String?) {
        guard let imageData = getImageCandidateData(from: pasteboard) else { return }

        let archive = captureRichArchive(from: pasteboard)
        let isRich = archive != nil
        Task { [weak self] in
            guard let pngData = await Task.detached(priority: .userInitiated, operation: {
                Self.normalizedPNGData(
                    from: imageData,
                    maxInputBytes: Self.maxImageInputBytes,
                    maxRasterPixels: Self.maxRasterPixels,
                    sourceDescription: "pasteboard image"
                )
            }).value else { return }
            let fingerprint = ClipboardContentFingerprint.image(pngData)

            guard let self, self.markContentFingerprintIfNew(fingerprint) else { return }
            if let filename = self.store.saveImage(pngData) {
                var item = ClipboardItem.image(filename: filename, sourceApp: sourceApp)
                item.hasRichContent = isRich
                self.store.add(item, richArchive: archive)
            }
        }
    }

    private func markContentFingerprintIfNew(_ fingerprint: ClipboardContentFingerprint) -> Bool {
        guard fingerprint != lastContentFingerprint else { return false }
        lastContentFingerprint = fingerprint
        return true
    }
    
    /// Capture every representation of the current pasteboard item, but only when the
    /// copy is "rich" (carries RTF/RTFD/HTML/PDF) — so paste can replay it with full
    /// fidelity (#11). Plain text and simple images return nil and use the fast path.
    private func captureRichArchive(from pasteboard: NSPasteboard) -> PasteboardArchive? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        let utis = item.types.map(\.rawValue)
        guard PasteboardArchive.isRich(utis: utis) else { return nil }

        let budget = 16 * 1024 * 1024  // skip oversized payloads rather than store them
        var total = 0
        var reps: [PasteboardArchive.Representation] = []
        for type in item.types {
            guard let data = item.data(forType: type) else { continue }
            total += data.count
            if total > budget { return nil }
            reps.append(.init(uti: type.rawValue, data: data))
        }
        return reps.isEmpty ? nil : PasteboardArchive(representations: reps)
    }

    private func getImageCandidateData(from pasteboard: NSPasteboard) -> Data? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                return data
            }
        }
        
        return nil
    }
    
    /// Check if a file path points to an image by examining its UTType
    private func isImageFile(_ filePath: String) -> Bool {
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        
        if let utType = UTType(filenameExtension: fileExtension) {
            return utType.conforms(to: .image)
        }
        return false
    }
    
    private struct ImageFileCapture: Sendable {
        let pngData: Data
        let fingerprint: ClipboardContentFingerprint
        let sourceApp: String?

        func item(with filename: String) -> ClipboardItem {
            ClipboardItem.image(filename: filename, sourceApp: sourceApp)
        }
    }

    /// Read image file from disk and normalize to PNG. Runs off the main actor.
    private nonisolated static func imageFileCapture(_ filePath: String, sourceApp: String?) -> ImageFileCapture? {
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
            
            return ImageFileCapture(
                pngData: pngData,
                fingerprint: ClipboardContentFingerprint.image(pngData),
                sourceApp: sourceApp
            )
        } catch {
            Log.capture.error("Error processing image file from pasteboard file list: \(error.localizedDescription)")
            return nil
        }
    }

    /// Normalise arbitrary raster bytes to PNG using a single `CGImageSource` for both the
    /// pixel-budget check and the re-encode: no TIFF/bitmap round-trip, one
    /// decode, no uncompressed-bitmap allocation. Off the main actor.
    private nonisolated static func normalizedPNGData(
        from data: Data,
        maxInputBytes: Int,
        maxRasterPixels: Int64,
        sourceDescription: String
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
        return PNGEncoder.encode(cgImage)
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
