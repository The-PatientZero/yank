import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

struct SpotlightDocument: Equatable, Sendable {
    let identifier: String
    let title: String
    let contentDescription: String
}

protocol SpotlightIndexClient: Sendable {
    func index(_ documents: [SpotlightDocument]) async throws
    func delete(identifiers: [String]) async throws
    func delete(domainIdentifiers: [String]) async throws
}

private struct SystemSpotlightIndexClient: SpotlightIndexClient, @unchecked Sendable {
    let index: CSSearchableIndex

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    func index(_ documents: [SpotlightDocument]) async throws {
        let items = documents.map { document in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = document.title
            attributes.contentDescription = document.contentDescription
            return CSSearchableItem(
                uniqueIdentifier: document.identifier,
                domainIdentifier: SpotlightIndexStorage.domainIdentifier,
                attributeSet: attributes
            )
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func delete(identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func delete(domainIdentifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Reconciles Yank's opt-in Spotlight domain. State advances only after the corresponding
/// system operation succeeds, so failed updates and deletions remain eligible for retry.
actor SpotlightIndexStorage {
    static let domainIdentifier = "yank.clips"
    private static let log = Logger(subsystem: "com.thepatientzero.yank", category: "spotlight")

    private let client: any SpotlightIndexClient
    private var indexedRevisions: [String: String] = [:]
    private var hasCleanProcessBaseline = false
    private var debounced: Task<Void, Never>?
    private var operationTask: Task<Void, any Error>?
    private var operationID: UInt64 = 0

    private enum Operation: Sendable {
        case reconcile([ClipboardItem])
        case clear
    }

    init(client: any SpotlightIndexClient = SystemSpotlightIndexClient()) {
        self.client = client
    }

    func index(_ items: [ClipboardItem]) async throws {
        debounced?.cancel()
        debounced = nil
        try await enqueue(.reconcile(items)).value
    }

    func schedule(_ items: [ClipboardItem], delay: TimeInterval = 0.6) {
        let snapshot = items
        debounced?.cancel()
        debounced = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, delay)))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                try await self.enqueue(.reconcile(snapshot)).value
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("Spotlight reconciliation failed: \(error.localizedDescription)")
            }
        }
    }

    func clear() async throws {
        debounced?.cancel()
        debounced = nil
        try await enqueue(.clear).value
    }

    private func enqueue(_ operation: Operation) -> Task<Void, any Error> {
        let prior = operationTask
        operationID &+= 1
        let id = operationID
        let task = Task { [weak self] in
            if let prior { _ = await prior.result }
            guard let self else { return }
            do {
                switch operation {
                case .reconcile(let items):
                    try await self.reconcile(items)
                case .clear:
                    try await self.client.delete(domainIdentifiers: [Self.domainIdentifier])
                    await self.markCleared()
                }
                await self.finishOperation(id: id)
            } catch {
                await self.finishOperation(id: id)
                throw error
            }
        }
        operationTask = task
        return task
    }

    private func markCleared() {
        indexedRevisions.removeAll()
        hasCleanProcessBaseline = true
    }

    private func finishOperation(id: UInt64) {
        if operationID == id { operationTask = nil }
    }

    private func reconcile(_ items: [ClipboardItem]) async throws {
        // In-memory revision tracking cannot know which Yank records survived a prior app
        // process. Clear only Yank's domain once per process before rebuilding the desired
        // set, preventing a clip deleted just before termination from lingering in Spotlight.
        if !hasCleanProcessBaseline {
            try await client.delete(domainIdentifiers: [Self.domainIdentifier])
            indexedRevisions.removeAll()
            hasCleanProcessBaseline = true
        }
        var documents: [String: SpotlightDocument] = [:]
        for item in items {
            guard let document = Self.document(for: item) else { continue }
            documents[document.identifier] = document
        }
        let desiredRevisions = documents.mapValues(Self.revision(for:))
        let changed = documents.values.filter {
            indexedRevisions[$0.identifier] != desiredRevisions[$0.identifier]
        }
        let removed = indexedRevisions.keys.filter { documents[$0] == nil }

        if !changed.isEmpty {
            try await client.index(changed.sorted { $0.identifier < $1.identifier })
            for document in changed {
                indexedRevisions[document.identifier] = desiredRevisions[document.identifier]
            }
        }
        if !removed.isEmpty {
            try await client.delete(identifiers: removed.sorted())
            for identifier in removed {
                indexedRevisions.removeValue(forKey: identifier)
            }
        }
    }

    private static func document(for item: ClipboardItem) -> SpotlightDocument? {
        guard !item.isDeleted, let text = item.textContent, !text.isEmpty else { return nil }
        let snippet = snippet(from: text)
        return SpotlightDocument(
            identifier: item.id.uuidString,
            title: snippet.isEmpty ? "Yank clip" : snippet,
            contentDescription: snippet
        )
    }

    private static func revision(for document: SpotlightDocument) -> String {
        document.title + "\u{1F}" + document.contentDescription
    }

    /// First non-empty line, trimmed and length-capped: a useful result without exposing
    /// a full clipboard body to the system index or lock-screen suggestions.
    private static func snippet(from text: String, limit: Int = 100) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(limit))
    }
}

enum SpotlightIndexer {
    private static let storage = SpotlightIndexStorage()

    static func index(_ items: [ClipboardItem]) {
        Task {
            do {
                try await storage.index(items)
            } catch {
                Logger.spotlight.error("Spotlight indexing failed: \(error.localizedDescription)")
            }
        }
    }

    static func schedule(_ items: [ClipboardItem], delay: TimeInterval = 0.6) {
        Task { await storage.schedule(items, delay: delay) }
    }

    static func clear() {
        Task {
            do {
                try await storage.clear()
            } catch {
                Logger.spotlight.error("Spotlight clear failed: \(error.localizedDescription)")
            }
        }
    }
}

private extension Logger {
    static let spotlight = Logger(subsystem: "com.thepatientzero.yank", category: "spotlight")
}
