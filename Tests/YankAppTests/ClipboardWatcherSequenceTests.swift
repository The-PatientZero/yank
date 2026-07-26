import AppKit
import Darwin
import Foundation
import Testing
@testable import Yank

private final class StubPasteboardPayloadReader: PasteboardPayloadReading {
    private var generations: [Int]
    private var generationIndex = 0
    let typeIdentifiers: [String]
    private let paths: [String]?
    private let representations: [String: Data]

    init(
        generations: [Int],
        typeIdentifiers: [String],
        paths: [String]? = nil,
        representations: [String: Data] = [:]
    ) {
        self.generations = generations
        self.typeIdentifiers = typeIdentifiers
        self.paths = paths
        self.representations = representations
    }

    var changeCount: Int {
        let index = min(generationIndex, generations.count - 1)
        generationIndex += 1
        return generations[index]
    }

    func filePaths() -> [String]? {
        paths
    }

    func data(forType identifier: String) -> Data? {
        representations[identifier]
    }
}

@Suite("Clipboard Watcher Paste Sequence")
@MainActor
struct ClipboardWatcherSequenceTests {
    @Test("Collecting uses the fast poll interval")
    func collectingUsesFastPolling() {
        #expect(ClipboardWatcher.pollInterval(sequenceCollectionActive: true) == 0.1)
    }

    @Test("Normal capture uses the power-saving poll interval")
    func normalCaptureUsesDefaultPolling() {
        #expect(ClipboardWatcher.pollInterval(sequenceCollectionActive: false) == 0.5)
    }

    @Test("Only the exact app-owned pasteboard generation is suppressed")
    func exactGenerationSuppression() {
        var suppression = PasteboardChangeSuppression()
        suppression.register(41)

        let suppressesEarlier = suppression.shouldSuppress(40)
        let suppressesExact = suppression.shouldSuppress(41)
        let suppressesLater = suppression.shouldSuppress(42)
        #expect(!suppressesEarlier)
        #expect(suppressesExact)
        #expect(!suppressesLater)
    }

    @Test("An intervening external generation is not suppressed by an app write receipt")
    func interveningExternalGenerationRemainsEligible() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.thepatientzero.yank.tests.receipt.\(UUID().uuidString)")
        )
        let receipt = try #require(
            PasteController.copyTextToClipboard("app-owned", pasteboard: pasteboard)
        )
        #expect(receipt.generation == pasteboard.changeCount)

        pasteboard.clearContents()
        #expect(pasteboard.setString("external", forType: .string))
        let externalGeneration = pasteboard.changeCount
        #expect(externalGeneration > receipt.generation)

        var suppression = PasteboardChangeSuppression()
        suppression.register(receipt.generation)
        let suppressesExternalGeneration = suppression.shouldSuppress(externalGeneration)
        #expect(!suppressesExternalGeneration)
    }

    @Test("Payload materialization rejects a generation that changes during extraction")
    func rejectsGenerationChange() {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let reader = StubPasteboardPayloadReader(
            generations: [7, 8],
            typeIdentifiers: [stringType],
            representations: [stringType: Data("hello".utf8)]
        )

        let snapshot = PasteboardPayloadMaterializer.materialize(
            reader: reader,
            expectedGeneration: 7,
            limits: .capture
        )

        #expect(snapshot == nil)
    }

    @Test("Materialization enforces representation and aggregate byte budgets")
    func enforcesPayloadByteBudgets() throws {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let richType = "public.rtf"
        let representationLimits = PasteboardPayloadMaterializer.Limits(
            maxTextBytes: 8,
            maxImageBytes: 8,
            maxRichRepresentationBytes: 3,
            maxRichArchiveBytes: 8,
            maxPayloadBytes: 8,
            maxTypeCount: 4,
            maxTypeIdentifierBytes: 64,
            maxFileCount: 2,
            maxFilePathBytes: 32
        )
        let oversizedRepresentationReader = StubPasteboardPayloadReader(
            generations: [12, 12],
            typeIdentifiers: [stringType, richType],
            representations: [
                stringType: Data("text".utf8),
                richType: Data(repeating: 1, count: 4)
            ]
        )

        let representationSnapshot = try #require(PasteboardPayloadMaterializer.materialize(
            reader: oversizedRepresentationReader,
            expectedGeneration: 12,
            limits: representationLimits
        ))
        #expect(representationSnapshot.payload == .text("text", richArchive: nil))

        let aggregateLimits = PasteboardPayloadMaterializer.Limits(
            maxTextBytes: 8,
            maxImageBytes: 8,
            maxRichRepresentationBytes: 4,
            maxRichArchiveBytes: 6,
            maxPayloadBytes: 8,
            maxTypeCount: 4,
            maxTypeIdentifierBytes: 64,
            maxFileCount: 2,
            maxFilePathBytes: 32
        )
        let oversizedAggregateReader = StubPasteboardPayloadReader(
            generations: [13, 13],
            typeIdentifiers: [stringType, richType],
            representations: [
                stringType: Data("text".utf8),
                richType: Data(repeating: 1, count: 3)
            ]
        )
        let aggregateSnapshot = try #require(PasteboardPayloadMaterializer.materialize(
            reader: oversizedAggregateReader,
            expectedGeneration: 13,
            limits: aggregateLimits
        ))

        #expect(aggregateSnapshot.payload == .text("text", richArchive: nil))
        #expect(aggregateSnapshot.payload.retainedByteCount <= aggregateLimits.maxPayloadBytes)
    }

    @Test("Oversized primary payload is never retained")
    func rejectsOversizedPrimaryPayload() throws {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let limits = PasteboardPayloadMaterializer.Limits(
            maxTextBytes: 3,
            maxImageBytes: 8,
            maxRichRepresentationBytes: 8,
            maxRichArchiveBytes: 8,
            maxPayloadBytes: 8,
            maxTypeCount: 4,
            maxTypeIdentifierBytes: 64,
            maxFileCount: 2,
            maxFilePathBytes: 32
        )
        let reader = StubPasteboardPayloadReader(
            generations: [19, 19],
            typeIdentifiers: [stringType],
            representations: [stringType: Data("four".utf8)]
        )

        let snapshot = try #require(PasteboardPayloadMaterializer.materialize(
            reader: reader,
            expectedGeneration: 19,
            limits: limits
        ))

        #expect(snapshot.payload == .unsupported)
        #expect(snapshot.payload.retainedByteCount == 0)
    }

    @Test("Normalized PNG output and aggregate retained bytes stay bounded")
    func normalizedPNGAndAggregateBudgets() throws {
        let sourcePNG = try makeOnePixelPNG()
        let oversizedOutput = ClipboardWatcher.normalizedPNGData(
            from: sourcePNG,
            maxInputBytes: sourcePNG.count,
            maxOutputBytes: 8,
            maxRasterPixels: 1,
            sourceDescription: "test",
            encoder: { _ in Data(repeating: 0xAA, count: 9) }
        )
        #expect(oversizedOutput == nil)

        let archive = PasteboardArchive(representations: [
            .init(uti: "public.rtf", data: Data(repeating: 0xBB, count: 4))
        ])
        let aggregateLimits = PasteboardPayloadMaterializer.Limits(
            maxTextBytes: 16,
            maxImageBytes: max(sourcePNG.count, 8),
            maxRichRepresentationBytes: 4,
            maxRichArchiveBytes: 4,
            maxPayloadBytes: 10,
            maxTypeCount: 4,
            maxTypeIdentifierBytes: 64,
            maxFileCount: 2,
            maxFilePathBytes: 32
        )
        let oversizedAggregate = ClipboardWatcher.normalizedImagePayload(
            from: sourcePNG,
            richArchive: archive,
            limits: aggregateLimits,
            maxRasterPixels: 1,
            sourceDescription: "test",
            encoder: { _ in Data(repeating: 0xCC, count: 8) }
        )
        #expect(oversizedAggregate == .unsupported)
    }

    @Test("Named pasteboard is materialized from a utility task")
    func materializesNamedPasteboardOffMainActor() async throws {
        let name = NSPasteboard.Name("com.thepatientzero.yank.tests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        #expect(pasteboard.setString("worker payload", forType: .string))
        let generation = pasteboard.changeCount

        let result = await Task.detached(priority: .utility) {
            (
                pthread_main_np() != 0,
                PasteboardPayloadMaterializer.materialize(
                    pasteboardName: name.rawValue,
                    expectedGeneration: generation
                )
            )
        }.value

        #expect(!result.0)
        let snapshot = try #require(result.1)
        #expect(snapshot.payload == .text("worker payload", richArchive: nil))
    }

    @Test("Capture image and rich preparation plus writes run off the main thread")
    func persistsCaptureBlobsOffMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YankCaptureBlobWorkerTests-\(UUID().uuidString)", isDirectory: true)
        let directories = ClipboardCaptureBlobPersistence.Directories(
            images: root.appendingPathComponent("images", isDirectory: true),
            texts: root.appendingPathComponent("texts", isDirectory: true),
            rich: root.appendingPathComponent("rich", isDirectory: true)
        )
        for directory in [directories.images, directories.texts, directories.rich] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PasteboardArchive(representations: [
            .init(uti: "public.rtf", data: Data("rich".utf8))
        ])

        let result = await Task.detached(priority: .utility) {
            (
                pthread_main_np() != 0,
                ClipboardCaptureBlobPersistence.persist(
                    primary: .image(Data([0x89, 0x50, 0x4E, 0x47])),
                    richArchive: archive,
                    directories: directories
                )
            )
        }.value

        #expect(!result.0)
        let persisted = try #require(result.1)
        let imageFilename = try #require(persisted.primaryFilename)
        let richFilename = try #require(persisted.richFilename)
        #expect(FileManager.default.fileExists(
            atPath: directories.images.appendingPathComponent(imageFilename).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: directories.rich.appendingPathComponent(richFilename).path
        ))

        let bounded = await Task.detached(priority: .utility) {
            ClipboardCaptureBlobPersistence.persist(
                primary: nil,
                richArchive: archive,
                directories: directories,
                richMaximumBytes: 1
            )
        }.value
        #expect(bounded?.richFilename == nil)
    }

    @Test("Capture application remains FIFO when materialization finishes out of order")
    func captureApplicationIsFIFO() async {
        let queue = SerialCaptureQueue<Int>()
        var applied: [Int] = []

        queue.enqueue(
            loader: {
                try? await Task.sleep(for: .milliseconds(100))
                return 1
            },
            apply: { applied.append($0) }
        )
        queue.enqueue(
            loader: { 2 },
            apply: { applied.append($0) }
        )

        await queue.waitUntilIdle()

        #expect(applied == [1, 2])
    }

    @Test("Capture application remains FIFO while an earlier disk phase is suspended")
    func captureApplicationIsFIFOAcrossSuspendingApply() async {
        let queue = SerialCaptureQueue<Int>()
        var applied: [Int] = []

        queue.enqueue(
            loader: { 1 },
            apply: {
                try? await Task.sleep(for: .milliseconds(100))
                applied.append($0)
            }
        )
        queue.enqueue(
            loader: { 2 },
            apply: { applied.append($0) }
        )

        await queue.waitUntilIdle()

        #expect(applied == [1, 2])
    }

    @Test("Cancellation prevents late materialization from applying")
    func cancellationPreventsLateApplication() async {
        let queue = SerialCaptureQueue<Int>()
        var applied: [Int] = []

        queue.enqueue(
            loader: {
                try? await Task.sleep(for: .milliseconds(100))
                return 1
            },
            apply: { applied.append($0) }
        )
        queue.cancelAll()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(applied.isEmpty)
    }

    private func makeOnePixelPNG() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        return try #require(PNGEncoder.encode(image))
    }
}
