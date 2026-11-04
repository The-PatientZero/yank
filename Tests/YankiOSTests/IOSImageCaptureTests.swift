import Foundation
import Testing
import UIKit
@testable import YankiOS

@Suite
@MainActor
struct IOSImageCaptureTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])

    /// Counts what one foreground refresh read and saved.
    private final class Recorder {
        var textReads = 0
        var imageReads = 0
        var savedTexts: [String] = []
        var savedImages: [Data] = []
    }

    private func refresh(
        _ coordinator: IOSForegroundRefreshCoordinator,
        generation: Int,
        types: [String],
        text: String? = nil,
        image: PasteboardImageReader.Result = .png(png),
        pending: IOSForegroundCaptureOutcome? = nil,
        recorder: Recorder
    ) async -> Bool {
        await coordinator.processPasteboard(
            pasteboardChangeCount: generation,
            pasteboardTypes: types,
            isAutomaticCaptureAuthorized: { true },
            readText: {
                recorder.textReads += 1
                return text
            },
            capture: { text, _, _ in
                recorder.savedTexts.append(text)
                return .durable
            },
            readImage: {
                recorder.imageReads += 1
                return image
            },
            captureImage: { data, _ in
                recorder.savedImages.append(data)
                return .durable
            },
            retryPendingCapture: { _ in pending }
        )
    }

    // MARK: - Automatic capture

    @Test("An image without plain text is saved once, without reading text")
    func savesImageOnce() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let recorder = Recorder()

        let first = await refresh(coordinator, generation: 3, types: ["public.png"], recorder: recorder)
        let second = await refresh(coordinator, generation: 3, types: ["public.png"], recorder: recorder)

        #expect(first)
        #expect(!second)
        #expect(recorder.savedImages == [Self.png])
        #expect(recorder.imageReads == 1)
        #expect(recorder.textReads == 0)
    }

    @Test("Plain text beside an image is saved as text")
    func plainTextWins() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let recorder = Recorder()

        let captured = await refresh(
            coordinator, generation: 4, types: ["public.utf8-plain-text", "public.png"],
            text: "caption", recorder: recorder
        )

        #expect(captured)
        #expect(recorder.savedTexts == ["caption"])
        #expect(recorder.imageReads == 0)
    }

    @Test("Empty plain text beside an image saves the image")
    func emptyTextFallsBackToImage() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let recorder = Recorder()

        let captured = await refresh(
            coordinator, generation: 5, types: ["public.utf8-plain-text", "public.png"],
            text: "  ", recorder: recorder
        )

        #expect(captured)
        #expect(recorder.savedTexts.isEmpty)
        #expect(recorder.savedImages == [Self.png])
    }

    @Test("A denied image read is tried again on the next visit")
    func unreadableImageStaysRetryable() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let recorder = Recorder()

        let denied = await refresh(
            coordinator, generation: 6, types: ["public.png"], image: .unreadable, recorder: recorder
        )
        let allowed = await refresh(coordinator, generation: 6, types: ["public.png"], recorder: recorder)

        #expect(!denied)
        #expect(allowed)
        #expect(recorder.imageReads == 2)
        #expect(recorder.savedImages == [Self.png])
    }

    @Test("An image that can never be saved is acknowledged and not read again")
    func unsupportedImageIsAcknowledged() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let recorder = Recorder()

        _ = await refresh(
            coordinator, generation: 7, types: ["public.png"], image: .unsupported, recorder: recorder
        )
        _ = await refresh(coordinator, generation: 7, types: ["public.png"], recorder: recorder)

        #expect(recorder.imageReads == 1)
        #expect(recorder.savedImages.isEmpty)
    }

    @Test("A failed save is retried without reading the clipboard again")
    func pendingCaptureRetriesBeforeReading() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let recorder = Recorder()

        let captured = await refresh(
            coordinator, generation: 8, types: ["public.png"], pending: .durable, recorder: recorder
        )

        #expect(captured)
        #expect(recorder.imageReads == 0)
        #expect(recorder.textReads == 0)
        #expect(recorder.savedImages.isEmpty)
    }

    // MARK: - Reading images

    @Test("The reader picks a decodable type, compact formats first")
    func preferredImageTypeSkipsUndecodableAndLargeFormats() {
        #expect(PasteboardImageReader.preferredImageType(
            in: ["public.svg-image", "public.tiff", "public.png"]
        ) == "public.png")
        #expect(PasteboardImageReader.preferredImageType(in: ["public.tiff"]) == "public.tiff")
        #expect(PasteboardImageReader.preferredImageType(in: ["public.svg-image"]) == nil)
        #expect(PasteboardImageReader.preferredImageType(in: ["public.utf8-plain-text"]) == nil)
    }

    @Test("Normalizing turns a real image into a PNG and rejects other data")
    func normalizeAcceptsImagesOnly() async throws {
        let encoded = try #require(Self.jpegData(width: 40, height: 30))

        let result = await PasteboardImageReader.normalize(encoded)

        guard case let .png(png) = result else {
            Issue.record("Expected a PNG, got \(result)")
            return
        }
        #expect(UIImage(data: png)?.size == CGSize(width: 40, height: 30))
        #expect(await PasteboardImageReader.normalize(Data("text".utf8)) == .unsupported)
    }

    @Test("A file larger than the source limit is rejected before it is read")
    func oversizedFileIsUnsupported() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImageCaptureTests-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ShareImageImportPolicy.maxEncodedSourceFileBytes + 1))
        try handle.close()

        #expect(await PasteboardImageReader.normalize(fileAt: url) == .unsupported)
    }

    // MARK: - Store

    @Test("A captured image is stored durably with its blob")
    func storeSavesForegroundImage() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        let imageData = try #require(Self.jpegData(width: 8, height: 8))

        let outcome = await store.captureForegroundImage(imageData, pasteboardGeneration: 11)

        #expect(outcome == .durable)
        let item = try #require(store.items.first)
        #expect(item.type == .image)
        let blobURL = try #require(store.blobURL(for: item))
        #expect(try Data(contentsOf: blobURL) == imageData)
        let snapshot = try HistorySnapshotLoader.load(
            historyURL: fixture.context.historyURL,
            tombstonesURL: fixture.context.tombstonesURL
        ).get()
        #expect(snapshot.items.first?.id == item.id)
    }

    @Test("A failed image save is retried as the same clip")
    func storeRetriesPendingImageWithoutDuplicating() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)
        await store.hydrate()
        try FileManager.default.createDirectory(at: fixture.context.historyURL, withIntermediateDirectories: false)

        let failed = await store.captureForegroundImage(Self.png, pasteboardGeneration: 12)
        try FileManager.default.removeItem(at: fixture.context.historyURL)
        let retried = await store.retryPendingForegroundCapture(pasteboardGeneration: 12)

        #expect(failed == .retryableFailure)
        #expect(retried == .durable)
        #expect(store.items.filter { $0.type == .image }.count == 1)
        #expect(await store.retryPendingForegroundCapture(pasteboardGeneration: 12) == nil)
    }

    // MARK: - Save Clipboard shortcut

    @Test("The shortcut resolves storage before reading an image")
    func shortcutImageResolvesStorageFirst() async {
        var didRead = false

        await #expect(throws: CaptureClipIntent.CaptureError.storageUnavailable) {
            try await CaptureClipIntent.captureImage(
                resolveAppGroup: { nil },
                readImage: {
                    didRead = true
                    return .png(Self.png)
                }
            )
        }

        #expect(!didRead)
    }

    @Test("A shortcut image is imported as an image clip from Shortcuts")
    func shortcutImageImportsAsImage() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = ClipStore(context: fixture.context)

        try await CaptureClipIntent.enqueue(imagePNG: Self.png, in: fixture.context.shareInbox)
        let sources = await store.drainShareInbox()

        #expect(store.items.first?.type == .image)
        #expect(store.items.first?.sourceApp == "Shortcuts")
        #expect(sources == ["Shortcuts"])
    }

    @Test("A shortcut image that cannot be read or saved reports why")
    func shortcutImageErrors() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        await #expect(throws: CaptureClipIntent.CaptureError.imageUnreadable) {
            try await CaptureClipIntent.captureImage(
                resolveAppGroup: { AppGroupContainer(url: fixture.root) },
                readImage: { .unreadable }
            )
        }
        await #expect(throws: CaptureClipIntent.CaptureError.imageTooLarge) {
            try await CaptureClipIntent.captureImage(
                resolveAppGroup: { AppGroupContainer(url: fixture.root) },
                readImage: { .unsupported }
            )
        }
    }

    // MARK: - Helpers

    private static func jpegData(width: Int, height: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImageCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "IOSImageCaptureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        return Fixture(
            root: root,
            defaultsName: defaultsName,
            context: AppGroupContext(containerURL: root, defaults: defaults)
        )
    }

    private struct Fixture {
        let root: URL
        let defaultsName: String
        let context: AppGroupContext

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
    }
}
