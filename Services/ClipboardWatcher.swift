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
        let payload = materializedPayload(
            reader: reader,
            typeIdentifiers: typeIdentifiers,
            cachedRepresentations: &cachedRepresentations,
            limits: limits
        )
        return stableSnapshot(
            generation: expectedGeneration,
            payload: payload,
            reader: reader,
            limits: limits
        )
    }

    private nonisolated static func materializedPayload(
        reader: PasteboardPayloadReading,
        typeIdentifiers: [String],
        cachedRepresentations: inout [String: Data],
        limits: Limits
    ) -> PasteboardPayload {
        if let filePaths = reader.filePaths(), !filePaths.isEmpty {
            guard filePaths.count <= limits.maxFileCount,
                  filePaths.allSatisfy({ $0.utf8.count <= limits.maxFilePathBytes }) else {
                return .unsupported
            }
            return .filePaths(filePaths)
        }

        guard let textData = reader.data(
            forType: NSPasteboard.PasteboardType.string.rawValue
        ) else {
            return imagePayload(
                reader: reader,
                typeIdentifiers: typeIdentifiers,
                cachedRepresentations: &cachedRepresentations,
                limits: limits
            )
        }
        guard textData.count <= limits.maxTextBytes else { return .unsupported }

        cachedRepresentations[NSPasteboard.PasteboardType.string.rawValue] = textData
        guard let text = String(data: textData, encoding: .utf8), !text.isEmpty else {
            return imagePayload(
                reader: reader,
                typeIdentifiers: typeIdentifiers,
                cachedRepresentations: &cachedRepresentations,
                limits: limits
            )
        }
        return .text(
            text,
            richArchive: richArchive(
                reader: reader,
                typeIdentifiers: typeIdentifiers,
                cachedRepresentations: &cachedRepresentations,
                limits: limits
            )
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

enum PreparedClipboardCapture: Sendable {
    case fileText(String, sourceApp: String?, observedAt: Date)
    case text(
        TextCapturePlan,
        originalText: String,
        richArchive: PasteboardArchive?,
        sourceApp: String?,
        generation: Int,
        observedAt: Date
    )
    case image(
        Data,
        richArchive: PasteboardArchive?,
        sourceApp: String?,
        observedAt: Date
    )
    case unsupported
}

struct ClipboardCaptureContext: Sendable {
    let sourceApp: String?
    let observedBundleID: String?
    let observedAt: Date
    let settings: CaptureSettings
}
